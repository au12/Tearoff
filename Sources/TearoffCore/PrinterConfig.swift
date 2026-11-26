import Foundation

/// The printer's own settings, from its ^HH reply (the configuration label, as text):
/// lines like "1318                LABEL LENGTH" (value, a run of spaces, then the name).
public struct PrinterConfig: Equatable {
    public var values: [String: String]

    public init(values: [String: String]) { self.values = values }

    public subscript(_ name: String) -> String? { values[name] }

    public var mediaType: String? { self["MEDIA TYPE"] }
    public var printMode: String? { self["PRINT MODE"] }
    /// What the printer measured from one label to the next when it last calibrated, in dots.
    public var labelLengthDots: Int? { Self.int(self["LABEL LENGTH"]) }
    public var labelTop: Int? { Self.int(self["LABEL TOP"]) }
    public var leftPosition: Int? { Self.int(self["LEFT POSITION"]) }
    public var isContinuous: Bool { mediaType?.uppercased().contains("CONTINUOUS") ?? false }

    static func int(_ s: String?) -> Int? {
        s.flatMap { Int($0.replacingOccurrences(of: "+", with: "").trimmingCharacters(in: .whitespaces)) }
    }

    public static func parse(_ reply: String) -> PrinterConfig? {
        let line = try! NSRegularExpression(pattern: #"^\s*(.*\S)\s{2,}(\S.*?)\s*$"#)
        var v: [String: String] = [:]
        let clean = reply.filter { $0 != "\u{02}" && $0 != "\u{03}" }
        for raw in clean.split(whereSeparator: \.isNewline) {
            let s = String(raw)
            guard let m = line.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                  let value = Range(m.range(at: 1), in: s), let name = Range(m.range(at: 2), in: s) else { continue }
            v[s[name].uppercased()] = String(s[value])
        }
        return v["LABEL LENGTH"] == nil && v["MEDIA TYPE"] == nil ? nil : PrinterConfig(values: v)
    }

    public struct Finding: Equatable {
        public enum Level: Equatable { case info, warning }
        public var level: Level
        public var text: String
    }

    /// Things worth knowing, given the label size chosen in Tearoff.
    public func check(labelHeightDots h: Int, dpi: Int) -> [Finding] {
        func inches(_ d: Int) -> String { String(format: "%.2f in", Double(d) / Double(dpi)) }
        var out: [Finding] = []
        if isContinuous {
            out.append(Finding(level: .warning, text: "The printer is set for continuous paper, so it doesn’t line up on the gaps between labels and the print drifts. Load your labels and click Calibrate."))
        } else if let l = labelLengthDots, l > 0 {
            if l < h - dpi / 16 {
                out.append(Finding(level: .warning, text: "The printer measured \(inches(l)) from one label to the next, less than the \(inches(h)) label size chosen below, so labels will run into the next one. Choose your label size under Label stock, or load the roll under its guides and click Calibrate."))
            } else if l > h + dpi * 3 / 10 {
                out.append(Finding(level: .info, text: "The printer measured \(inches(l)) from one label to the next, \(inches(l - h)) more than the label size chosen below. If your labels are that long, that’s fine: use Shift down to center the print. If they’re \(inches(h)) labels, load the roll under its guides and click Calibrate."))
            }
        }
        if let t = labelTop, t != 0 {
            out.append(Finding(level: .info, text: "The printer has its own Label Top setting (\(t)), which moves everything it prints. Setting it can upset how the printer feeds; Tearoff’s Shift down is the safer place for this."))
        }
        if let p = leftPosition, p != 0 {
            out.append(Finding(level: .info, text: "The printer has its own Left Position setting (\(p)), which moves everything it prints sideways."))
        }
        return out
    }
}
