import Foundation

/// A printer plugged into the Mac by USB, as CUPS describes it.
public struct USBPrinterInfo: Equatable {
    /// CUPS device URI, e.g. `usb://Zebra%20Technologies/ZTC%20GX420d?serial=28J154300123`.
    public var uri: String
    public var makeAndModel: String
    /// IEEE 1284 device ID ("MANUFACTURER:Zebra Technologies;COMMAND SET:ZPL;MODEL:ZTC GX420d;…").
    public var deviceID: String

    public init(uri: String, makeAndModel: String = "", deviceID: String = "") {
        self.uri = uri
        self.makeAndModel = makeAndModel
        self.deviceID = deviceID
    }

    var fields: [String: String] { USBDevices.parseDeviceID(deviceID) }

    /// Manufacturer and model from the URI's path (`usb://MAKE/MODEL?…`).
    var uriParts: (make: String, model: String) {
        let path = uri.dropFirst("usb://".count).split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        let parts = path.split(separator: "/", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
        return (parts.first ?? "", parts.count > 1 ? parts[1] : "")
    }

    public var manufacturer: String { fields["MFG"] ?? fields["MANUFACTURER"] ?? uriParts.make }
    public var model: String { fields["MDL"] ?? fields["MODEL"] ?? uriParts.model }
    /// Printer languages it says it speaks ("ZPL", "EPL,ZPL"…), if its device ID says.
    public var commandSet: String? { fields["CMD"] ?? fields["COMMAND SET"] }
    public var serial: String? { USBDevices.serial(inURI: uri) }

    public var isZebra: Bool {
        manufacturer.lowercased().contains("zebra") || model.uppercased().hasPrefix("ZTC") || uri.lowercased().contains("zebra")
    }

    /// Speaks ZPL, Tearoff's language. nil when the printer didn't say and the model doesn't tell.
    public var speaksZPL: Bool? {
        if let cmd = commandSet?.uppercased(), !cmd.isEmpty { return cmd.contains("ZPL") }
        if USBDevices.eplOnly(model) { return false }
        return nil
    }

    /// "GX420d" from "ZTC GX420d", "ZD421-203dpi" from "ZTC ZD421-203dpi ZPL".
    public var displayName: String {
        var m = model.trimmingCharacters(in: .whitespaces)
        if m.uppercased().hasPrefix("ZTC ") { m = String(m.dropFirst(4)) }
        for suffix in [" ZPL", " EPL"] where m.uppercased().hasSuffix(suffix) { m = String(m.dropLast(suffix.count)) }
        if m.isEmpty { m = makeAndModel.isEmpty ? "USB printer" : makeAndModel }
        return m
    }

    public var dpi: Int { USBDevices.guessDPI(model: model) }
}

/// Reading what CUPS and the USB bus say about printers plugged into the Mac.
public enum USBDevices {

    /// `lpinfo --include-schemes usb -l -v`: "Device: uri = …" followed by indented "key = value" lines.
    public static func parseLPInfo(_ text: String) -> [USBPrinterInfo] {
        var out: [USBPrinterInfo] = []
        var current: USBPrinterInfo? = nil
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Device: ") {
                if let c = current { out.append(c) }
                current = nil
                if let eq = line.range(of: "uri = ") {
                    current = USBPrinterInfo(uri: String(line[eq.upperBound...]).trimmingCharacters(in: .whitespaces))
                }
                continue
            }
            guard current != nil, let eq = line.range(of: " = ") else { continue }
            let key = line[..<eq.lowerBound]
            let value = String(line[eq.upperBound...]).trimmingCharacters(in: .whitespaces)
            if key == "make-and-model" { current?.makeAndModel = value }
            if key == "device-id" { current?.deviceID = value }
        }
        if let c = current { out.append(c) }
        return out.filter { $0.uri.hasPrefix("usb://") }
    }

    /// A CUPS backend's device list, run directly: `class uri "make-and-model" "info" "device-id" "location"`.
    public static func parseBackendList(_ text: String) -> [USBPrinterInfo] {
        var out: [USBPrinterInfo] = []
        for line in text.split(separator: "\n") {
            let t = tokens(String(line))
            guard t.count >= 2, t[1].hasPrefix("usb://") else { continue }
            out.append(USBPrinterInfo(uri: t[1], makeAndModel: t.count > 2 ? t[2] : "", deviceID: t.count > 4 ? t[4] : ""))
        }
        return out
    }

    /// Splits on spaces, keeping "quoted strings" whole.
    static func tokens(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var quoted = false
        var started = false
        for ch in s {
            if ch == "\"" { quoted.toggle(); started = true; continue }
            if ch == " " && !quoted {
                if started { out.append(cur); cur = ""; started = false }
                continue
            }
            cur.append(ch)
            started = true
        }
        if started { out.append(cur) }
        return out
    }

    /// IEEE 1284 device ID fields, keys uppercased ("MFG", "MANUFACTURER", "CMD", "COMMAND SET", "MDL", "MODEL"…).
    public static func parseDeviceID(_ id: String) -> [String: String] {
        var out: [String: String] = [:]
        for part in id.split(separator: ";") {
            guard let colon = part.firstIndex(of: ":") else { continue }
            let key = part[..<colon].trimmingCharacters(in: .whitespaces).uppercased()
            let value = part[part.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { out[key] = value }
        }
        return out
    }

    public static func serial(inURI uri: String) -> String? {
        guard let q = uri.split(separator: "?", maxSplits: 1).dropFirst().first else { return nil }
        for item in q.split(separator: "&") {
            let kv = item.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0] == "serial" {
                let v = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                return v.isEmpty ? nil : v
            }
        }
        return nil
    }

    /// Two CUPS device URIs for the same USB printer (serials match, or make/model match when there is no serial).
    public static func sameDevice(_ a: String, _ b: String) -> Bool {
        guard a.hasPrefix("usb:"), b.hasPrefix("usb:") else { return a == b }
        if let sa = serial(inURI: a), let sb = serial(inURI: b) { return sa.caseInsensitiveCompare(sb) == .orderedSame }
        func path(_ u: String) -> String {
            let p = u.split(separator: "?", maxSplits: 1).first.map(String.init) ?? u
            return (p.removingPercentEncoding ?? p).lowercased()
        }
        return path(a) == path(b)
    }

    /// The URI CUPS's usb backend builds for a device: `usb://MAKE/MODEL?serial=SERIAL`.
    public static func uri(manufacturer: String, product: String, serial: String?) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?&=")
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
        var u = "usb://\(enc(manufacturer))/\(enc(product))"
        if let s = serial, !s.isEmpty { u += "?serial=\(s)" }
        return u
    }

    /// Resolution from the model name: "-300dpi"/"-600dpi" variants, and the x3x desktop
    /// models (GX430t, GK430…) are 300 dpi; everything else 203.
    public static func guessDPI(model: String) -> Int {
        let m = model.lowercased()
        if m.contains("600dpi") || m.contains("600 dpi") { return 600 }
        if m.contains("300dpi") || m.contains("300 dpi") { return 300 }
        if m.range(of: #"\b(gx|gk|gc|gt)\s?\d3\d"#, options: .regularExpression) != nil { return 300 }
        return 203
    }

    /// Zebras that only speak EPL: the LP/TLP 28xx family without the "-Z" suffix, and the ZP 505.
    public static func eplOnly(_ model: String) -> Bool {
        let m = model.uppercased().replacingOccurrences(of: " ", with: "")
        return m.range(of: #"T?LP2(844|824|742|746|722)(?!-?Z)|ZP505"#, options: .regularExpression) != nil
    }
}
