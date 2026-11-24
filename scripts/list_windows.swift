// Lists on-screen windows owned by an app (CI diagnostics): swift scripts/list_windows.swift Tearoff
import CoreGraphics
import Foundation

let owner = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Tearoff"
let info = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
var n = 0
for w in info where (w[kCGWindowOwnerName as String] as? String) == owner {
    n += 1
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    print("window \(w[kCGWindowNumber as String] ?? "?") layer \(w[kCGWindowLayer as String] ?? "?") onscreen \(w[kCGWindowIsOnscreen as String] ?? false) name '\(w[kCGWindowName as String] ?? "")' bounds \(b)")
}
print("\(n) window(s) for \(owner)")
