import Foundation
import IOKit
import TearoffCore

/// Printers plugged into this Mac by USB. Tearoff prints to them through a macOS print queue
/// (the Tearoff driver, or any queue fed raw ZPL), so finding one means finding its CUPS device URI.
public enum USBPrinters {

    /// A device on the USB bus.
    public struct BusDevice: Equatable {
        public var vendorID: Int
        public var manufacturer: String
        public var product: String
        public var serial: String
    }

    static let zebraVendorID = 0x0A5F

    /// USB printers, with the device URIs CUPS uses. Blocking (up to a few seconds): call off the main thread.
    public static func list() -> [USBPrinterInfo] {
        var found: [USBPrinterInfo] = []
        // 1. CUPS's own device list: exact URIs and IEEE 1284 IDs (works for admin users, no prompt)
        let r = Shell.run("/usr/sbin/lpinfo", ["--timeout", "8", "--include-schemes", "usb", "-l", "-v"])
        var cupsAnswered = r.status == 0
        if cupsAnswered { found = USBDevices.parseLPInfo(r.output) }
        // 2. the usb backend itself, when lpinfo isn't allowed
        if !cupsAnswered {
            let b = Shell.run("/usr/libexec/cups/backend/usb", [])
            cupsAnswered = b.status == 0
            if cupsAnswered { found = USBDevices.parseBackendList(b.output) }
        }
        // 3. CUPS couldn't be asked: build the URI its usb backend would use for each Zebra on the bus
        //    (when CUPS did answer and left a device out, it can't print to it, so neither can we)
        guard !cupsAnswered else { return found }
        for d in busDevices() where d.vendorID == zebraVendorID {
            let uri = USBDevices.uri(manufacturer: d.manufacturer.isEmpty ? "Zebra Technologies" : d.manufacturer,
                                     product: d.product, serial: d.serial.isEmpty ? nil : d.serial)
            if !found.contains(where: { USBDevices.sameDevice($0.uri, uri) }) {
                found.append(USBPrinterInfo(uri: uri, makeAndModel: "\(d.manufacturer) \(d.product)"))
            }
        }
        return found
    }

    /// Is the printer with this CUPS device URI plugged in and switched on?
    public static func isConnected(uri: String) -> Bool {
        let want = USBPrinterInfo(uri: uri)
        return busDevices().contains { d in
            if let s = want.serial, !d.serial.isEmpty { return s.caseInsensitiveCompare(d.serial) == .orderedSame }
            return !d.product.isEmpty && want.model.lowercased().contains(d.product.lowercased())
        }
    }

    /// Every device on the USB bus (IOKit; no permissions needed).
    public static func busDevices() -> [BusDevice] {
        var out: [BusDevice] = []
        guard let matching = IOServiceMatching("IOUSBHostDevice") else { return out }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return out }
        defer { _ = IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            let entry = service
            func string(_ keys: [String]) -> String {
                for k in keys {
                    if let v = IORegistryEntryCreateCFProperty(entry, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
                        return v.trimmingCharacters(in: .whitespaces)
                    }
                }
                return ""
            }
            var vendor = 0
            if let v = IORegistryEntryCreateCFProperty(entry, "idVendor" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber {
                vendor = v.intValue
            }
            out.append(BusDevice(vendorID: vendor,
                                 manufacturer: string(["USB Vendor Name", "kUSBVendorString"]),
                                 product: string(["USB Product Name", "kUSBProductString"]),
                                 serial: string(["USB Serial Number", "kUSBSerialNumberString"])))
            _ = IOObjectRelease(entry)
            service = IOIteratorNext(iterator)
        }
        return out
    }
}
