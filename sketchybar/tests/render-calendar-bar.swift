import AppKit
import Foundation

let output = CommandLine.arguments.dropFirst().first ?? "/tmp/calendar-bar-synthetic-offline.png"
let size = CGSize(width: 400, height: 50)
let image = NSImage(size: size)
func color(_ red: Int, _ green: Int, _ blue: Int) -> NSColor {
    NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
}
let surface = color(0x18, 0x1b, 0x1f)
let border = color(0x34, 0x3a, 0x40)
let primary = color(0xe7, 0xea, 0xed)
let muted = color(0x85, 0x8b, 0x92)
let accent = color(0xb8, 0xc0, 0xc8)
func font(_ postscriptName: String, _ size: CGFloat) -> NSFont {
    guard let value = NSFont(name: postscriptName, size: size) else {
        FileHandle.standardError.write(Data("Required synthetic calendar font is unavailable\n".utf8))
        exit(1)
    }
    return value
}
func sketchyBarMaxCharacters(_ text: String, limit: Int = 18) -> String {
    guard text.count > limit else { return text }
    return String(text.prefix(max(1, limit - 1))) + "…"
}

func draw(_ text: String, frame: CGRect, font: NSFont, color: NSColor, alignment: NSTextAlignment) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    paragraph.lineBreakMode = .byClipping
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
    let height = (text as NSString).size(withAttributes: attributes).height
    let centered = CGRect(x: frame.minX, y: frame.midY - height / 2, width: frame.width, height: height)
    (text as NSString).draw(in: centered, withAttributes: attributes)
}
image.lockFocus()
NSColor.clear.setFill()
CGRect(origin: .zero, size: size).fill()
let group = CGRect(x: 12, y: 12, width: 376, height: 26)
let path = NSBezierPath(roundedRect: group, xRadius: 9, yRadius: 9)
surface.setFill(); path.fill()
border.setStroke(); path.lineWidth = 1; path.stroke()
// Exact 260pt event split: 128pt title and 132pt supporting text.
let titleFont = font("JetBrainsMonoNF-SemiBold", 10)
let titleContentWidth: CGFloat = 114
let syntheticTitle = sketchyBarMaxCharacters("Synthetic review")
let overflowTitle = sketchyBarMaxCharacters("ABCDEFGHIJKLMNOPQRSTUV")
let titleSamples = [syntheticTitle, overflowTitle, String(repeating: "M", count: 17) + "…"]
guard syntheticTitle == "Synthetic review", overflowTitle == "ABCDEFGHIJKLMNOPQ…",
      titleSamples.allSatisfy({ ceil(($0 as NSString).size(withAttributes: [.font: titleFont]).width) <= titleContentWidth }) else {
    FileHandle.standardError.write(Data("Calendar title truncation or width budget failed\n".utf8))
    exit(1)
}
draw(syntheticTitle, frame: CGRect(x: 22, y: 12, width: titleContentWidth, height: 26), font: titleFont, color: primary, alignment: .left)
draw("in 25m · 45m ↗", frame: CGRect(x: 140, y: 12, width: 128, height: 26), font: font("JetBrainsMonoNF-Medium", 8.5), color: muted, alignment: .right)
// Exact 116pt date/time split: 58pt + 58pt.
draw("Thu Aug 6", frame: CGRect(x: 274, y: 12, width: 53, height: 26), font: font("JetBrainsMonoNF-SemiBold", 9), color: muted, alignment: .right)
draw("9:30 PM", frame: CGRect(x: 333, y: 12, width: 53, height: 26), font: font("JetBrainsMonoNF-Medium", 9), color: accent, alignment: .left)
image.unlockFocus()
guard let data = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: data),
      let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: output), options: .atomic)
print("Calendar bar synthetic renderer passed")
