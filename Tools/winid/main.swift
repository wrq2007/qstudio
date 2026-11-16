import CoreGraphics
import Foundation

let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list {
    guard let owner = w[kCGWindowOwnerName as String] as? String else { continue }
    let name = w[kCGWindowName as String] as? String ?? ""
    let num = w[kCGWindowNumber as String] as? Int ?? 0
    let layer = w[kCGWindowLayer as String] as? Int ?? 0
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let x = b["X"] as? Double ?? 0, y = b["Y"] as? Double ?? 0
    let ww = b["Width"] as? Double ?? 0, hh = b["Height"] as? Double ?? 0
    print("\(num)\t layer=\(layer)\t \(owner)\t [\(name)]\t \(Int(x)),\(Int(y)) \(Int(ww))x\(Int(hh))")
}
