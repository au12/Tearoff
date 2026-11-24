import Foundation

/// Parsed ~HS (host status) response.
public struct ZebraStatus: Equatable {
    public var paperOut = false
    public var paused = false
    public var headOpen = false
    public var ribbonOut = false
    public var thermalTransfer = false
    public var overTemperature = false
    public var underTemperature = false
    public var bufferFull = false
    public var formatsInBuffer = 0
    public var labelsRemaining = 0
    public var labelLengthDots = 0
    public var labelWaiting = false

    public init() {}

    public var isReady: Bool { !paperOut && !paused && !headOpen && !(ribbonOut && thermalTransfer) && !overTemperature }

    public var summary: String {
        if headOpen { return "Head open" }
        if paperOut { return "Out of labels" }
        if ribbonOut && thermalTransfer { return "Ribbon out" }
        if overTemperature { return "Head too hot" }
        if paused { return "Paused" }
        if labelWaiting { return "Label waiting to be taken" }
        if formatsInBuffer > 0 || labelsRemaining > 0 { return "Printing" }
        return "Ready"
    }

    /// Parses the three STX…ETX strings of a ~HS reply.
    public static func parse(_ reply: String) -> ZebraStatus? {
        let lines = framedStrings(reply)
        guard lines.count >= 2 else { return nil }
        let a = lines[0].split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        let b = lines[1].split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard a.count >= 8, b.count >= 9 else { return nil }
        var s = ZebraStatus()
        s.paperOut = a[1] == "1"
        s.paused = a[2] == "1"
        s.labelLengthDots = Int(a[3]) ?? 0
        s.formatsInBuffer = Int(a[4]) ?? 0
        s.bufferFull = a[5] == "1"
        if a.count >= 12 {
            s.underTemperature = a[10] == "1"
            s.overTemperature = a[11] == "1"
        }
        s.headOpen = b[2] == "1"
        s.ribbonOut = b[3] == "1"
        s.thermalTransfer = b[4] == "1"
        s.labelWaiting = b[7] == "1"
        s.labelsRemaining = Int(b[8]) ?? 0
        return s
    }

    /// Contents between STX (0x02) and ETX (0x03) markers.
    public static func framedStrings(_ s: String) -> [String] {
        var out: [String] = []
        var cur: String? = nil
        for ch in s.unicodeScalars {
            if ch.value == 2 { cur = "" }
            else if ch.value == 3 { if let c = cur { out.append(c) }; cur = nil }
            else if cur != nil { cur!.unicodeScalars.append(ch) }
        }
        return out
    }
}

/// Parsed ~HI (host identification) response, e.g. "GX420d-200dpi,V61.17.17Z,8,8192KB".
public struct ZebraIdentity: Equatable {
    public var model: String
    public var firmware: String
    public var dotsPerMillimeter: Int
    public var memory: String

    public var dpi: Int {
        switch dotsPerMillimeter {
        case 6: return 152
        case 12: return 300
        case 24: return 600
        default: return 203
        }
    }

    public static func parse(_ reply: String) -> ZebraIdentity? {
        guard let line = ZebraStatus.framedStrings(reply).first else { return nil }
        let p = line.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard p.count >= 3, !p[0].isEmpty else { return nil }
        var dpmm = Int(p[2]) ?? 8
        if let r = p[0].range(of: #"(\d{3})dpi"#, options: .regularExpression) {
            switch Int(p[0][r].dropLast(3)) ?? 0 {
            case 300: dpmm = 12
            case 600: dpmm = 24
            case 200, 203: dpmm = 8
            default: break
            }
        }
        return ZebraIdentity(model: p[0], firmware: p[1], dotsPerMillimeter: dpmm, memory: p.count > 3 ? p[3] : "")
    }
}

/// Best-effort carrier guess from a decoded barcode, for labelling previews.
public enum Carrier {
    public static func name(for codes: [String]) -> String? {
        for c in codes {
            let t = c.replacingOccurrences(of: " ", with: "")
            if t.hasPrefix("1Z") && t.count == 18 { return "UPS" }
        }
        for c in codes {
            let t = c.replacingOccurrences(of: " ", with: "")
            let digits = t.allSatisfy(\.isNumber)
            if digits && t.count >= 20 && (t.hasPrefix("9") || t.hasPrefix("420")) { return "USPS" }
            if t.hasPrefix("TBA") { return "Amazon" }
            if digits && (t.count == 12 || t.count == 15 || t.count == 34) { return "FedEx" }
            if t.hasPrefix("JJD") || (digits && t.count == 10) { return "DHL" }
        }
        return nil
    }

    /// The code most likely to be the tracking number.
    public static func trackingNumber(in codes: [String]) -> String? {
        if let ups = codes.first(where: { $0.hasPrefix("1Z") && $0.count == 18 }) { return ups }
        let usps = codes.filter { $0.allSatisfy(\.isNumber) && $0.count >= 20 }
        if let u = usps.max(by: { $0.count < $1.count }) {
            // IMpb carries "420" + ZIP routing before the tracking number
            if u.hasPrefix("420") {
                let rest = u.dropFirst(3)
                if rest.count > 22 { return String(rest.dropFirst(rest.count - 22)) }
            }
            return u
        }
        return codes.max(by: { $0.count < $1.count })
    }
}
