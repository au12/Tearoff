import Foundation

/// Axis-aligned rectangle in page *display* space: points, origin at the top-left
/// of the page as it is shown (after /Rotate), y growing downward.
public struct PageRect: Hashable, Codable, CustomStringConvertible {
    public var x0: Double
    public var y0: Double
    public var x1: Double
    public var y1: Double

    public init(x0: Double, y0: Double, x1: Double, y1: Double) {
        self.x0 = x0; self.y0 = y0; self.x1 = x1; self.y1 = y1
    }

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.init(x0: x, y0: y, x1: x + width, y1: y + height)
    }

    public var width: Double { x1 - x0 }
    public var height: Double { y1 - y0 }
    public var area: Double { max(0, width) * max(0, height) }
    public var midX: Double { (x0 + x1) / 2 }
    public var midY: Double { (y0 + y1) / 2 }
    public var isLandscape: Bool { width > height }

    /// Long side over short side (always >= 1).
    public var aspect: Double {
        let a = max(width, height), b = min(width, height)
        return b > 0 ? a / b : .infinity
    }

    public func intersection(_ o: PageRect) -> PageRect? {
        let r = PageRect(x0: max(x0, o.x0), y0: max(y0, o.y0), x1: min(x1, o.x1), y1: min(y1, o.y1))
        return r.width > 0 && r.height > 0 ? r : nil
    }

    public func intersectionArea(_ o: PageRect) -> Double { intersection(o)?.area ?? 0 }

    public func contains(x: Double, y: Double, pad: Double = 0) -> Bool {
        x >= x0 - pad && x <= x1 + pad && y >= y0 - pad && y <= y1 + pad
    }

    public func insetBy(_ d: Double) -> PageRect { PageRect(x0: x0 + d, y0: y0 + d, x1: x1 - d, y1: y1 - d) }

    public func scaled(by s: Double) -> PageRect { PageRect(x0: x0 * s, y0: y0 * s, x1: x1 * s, y1: y1 * s) }

    public var description: String {
        String(format: "(%.1f,%.1f %.2fx%.2fin)", x0, y0, width / 72, height / 72)
    }
}

/// Integer pixel rectangle (half-open).
public struct PixelRect: Hashable {
    public var x0: Int
    public var y0: Int
    public var x1: Int
    public var y1: Int
    public init(x0: Int, y0: Int, x1: Int, y1: Int) { self.x0 = x0; self.y0 = y0; self.x1 = x1; self.y1 = y1 }
    public var width: Int { x1 - x0 }
    public var height: Int { y1 - y0 }
}

/// Physical label stock.
public struct LabelSize: Hashable, Codable, CustomStringConvertible {
    public var width: Double    // inches
    public var height: Double   // inches
    public init(width: Double, height: Double) { self.width = width; self.height = height }

    public static let fourBySix = LabelSize(width: 4, height: 6)

    /// Long side / short side.
    public var aspect: Double { max(width, height) / max(0.01, min(width, height)) }

    public func dots(dpi: Int) -> (width: Int, height: Int) {
        (Int((width * Double(dpi)).rounded()), Int((height * Double(dpi)).rounded()))
    }

    public var description: String {
        func f(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v) }
        return "\(f(width))×\(f(height))"
    }

    /// Parses "4x6", "4×6", "2.25x1.25".
    public init?(string: String) {
        let parts = string.lowercased().replacingOccurrences(of: "×", with: "x")
            .replacingOccurrences(of: "in", with: "").split(separator: "x")
        guard parts.count == 2, let w = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let h = Double(parts[1].trimmingCharacters(in: .whitespaces)), w > 0, h > 0 else { return nil }
        self.init(width: w, height: h)
    }
}
