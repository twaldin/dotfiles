import AppKit
import Foundation

let fontName = "JetBrainsMono Nerd Font"
guard let font = NSFont(name: fontName, size: 8.5) else {
    FileHandle.standardError.write(Data("Required calendar font is unavailable\n".utf8))
    exit(1)
}
let titleFont = NSFont(name: fontName, size: 10)!
let titleAvailableWidth = 114.0 // Fixed 128pt title lane minus 10pt left and 4pt right insets.
for sample in ["Synthetic review", String(repeating: "M", count: 17) + "…"] {
    let width = ceil((sample as NSString).size(withAttributes: [.font: titleFont]).width)
    if width > titleAvailableWidth {
        FileHandle.standardError.write(Data("Calendar title width budget failed\n".utf8))
        exit(1)
    }
}

let availableWidth = 128.0 // Fixed 132pt detail field minus its 4pt right inset.
let samples = [
    "in 8d · 99d+ ↗",
    "ends in 99d+ · 99d+ ↗",
    "ends in 23h59m · 23h59m ↗",
    "ends in 98d23h · 98d23h ↗",
    "time unavailable ↗",
    "all day ↗",
    "in 98d23h · all day ↗",
    "STALE",
]
for sample in samples {
    let width = ceil((sample as NSString).size(withAttributes: [.font: font]).width)
    if width > availableWidth {
        FileHandle.standardError.write(Data("Calendar detail width budget failed\n".utf8))
        exit(1)
    }
}
print("Calendar detail font-width budget passed")
