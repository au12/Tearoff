// Prints the CGWindowID of the largest on-screen window owned by an app (CI screenshots).
//   swift scripts/window_id.swift Installer
import CoreGraphics
import Foundation

let owner = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Installer"
let info = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
let mine = info.filter { ($0[kCGWindowOwnerName as String] as? String) == owner && ($0[kCGWindowLayer as String] as? Int) == 0 }
let best = mine.max { a, b in
    let ba = a[kCGWindowBounds as String] as? [String: Double] ?? [:], bb = b[kCGWindowBounds as String] as? [String: Double] ?? [:]
    return (ba["Width"] ?? 0) * (ba["Height"] ?? 0) < (bb["Width"] ?? 0) * (bb["Height"] ?? 0)
}
if let w = best, let id = w[kCGWindowNumber as String] { print(id) } else { exit(1) }
