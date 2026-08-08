import AppKit
import CoreText
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
let output = arguments.first ?? "/tmp/calendar-bar-synthetic-offline.png"
let state = arguments.count > 1 ? arguments[1] : "idle"
guard ["idle", "event-hover", "date-hover", "system-hover"].contains(state) else {
    FileHandle.standardError.write(Data("Unknown calendar bar render state\n".utf8))
    exit(1)
}
let size = CGSize(width: 555, height: 50)
let image = NSImage(size: size)
func color(_ red: Int, _ green: Int, _ blue: Int) -> NSColor {
    NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
}
let eventIdle = color(0x24, 0x29, 0x32)
let dateIdle = color(0x30, 0x37, 0x44)
let systemIdle = color(0x3b, 0x43, 0x52)
let hover = color(0x4c, 0x56, 0x6a)
let primary = color(0xe7, 0xea, 0xed)
let muted = color(0xc5, 0xcb, 0xd3)
let accent = color(0xd8, 0xde, 0xe9)
func font(_ postscriptName: String, _ size: CGFloat) -> NSFont {
    guard let value = NSFont(name: postscriptName, size: size), value.fontName == postscriptName else {
        FileHandle.standardError.write(Data("Required exact synthetic calendar font is unavailable\n".utf8))
        exit(1)
    }
    return value
}
func sketchyWidth(_ text: String, font: NSFont) -> Int {
    let attributed = NSAttributedString(string: text, attributes: [.font: font])
    let line = CTLineCreateWithAttributedString(attributed)
    return Int(CTLineGetBoundsWithOptions(line, .useGlyphPathBounds).width + 1.5)
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

let calendarGlyph = "󰃭"
let fullTitle = calendarGlyph + " Review reliability report"
let displayedTitle = fullTitle
let detail = "in 3h47m · 30m ↗"
let titleFont = font("JetBrainsMonoNF-SemiBold", 9)
let detailFont = font("JetBrainsMonoNF-Medium", 8)
let titleWidth = sketchyWidth(displayedTitle, font: titleFont)
let detailWidth = sketchyWidth(detail, font: detailFont)
let eventWidth = 16 + 8 + titleWidth + detailWidth
guard eventWidth < 256 else {
    FileHandle.standardError.write(Data("Calendar intrinsic title allocation failed\n".utf8))
    exit(1)
}

image.lockFocus()
NSColor.clear.setFill()
CGRect(origin: .zero, size: size).fill()
let eventGroup = CGRect(x: 12, y: 12, width: eventWidth, height: 26)
let dateGroup = CGRect(x: eventGroup.maxX, y: 12, width: 116, height: 26)
let systemGroup = CGRect(x: dateGroup.maxX, y: 12, width: 168, height: 26)
guard eventGroup.width <= 256,
      eventGroup.maxX == dateGroup.minX,
      dateGroup.maxX == systemGroup.minX,
      eventGroup.width + dateGroup.width <= 372 else {
    FileHandle.standardError.write(Data("Calendar touching geometry failed\n".utf8))
    exit(1)
}
(state == "event-hover" ? hover : eventIdle).setFill()
eventGroup.fill()
(state == "date-hover" ? hover : dateIdle).setFill()
dateGroup.fill()
systemIdle.setFill()
systemGroup.fill()
if state == "system-hover" {
    hover.setFill()
    CGRect(x: systemGroup.minX, y: systemGroup.minY, width: 28, height: 26).fill()
}

let titleFrame = CGRect(x: eventGroup.minX + 8, y: eventGroup.minY,
                        width: CGFloat(titleWidth), height: eventGroup.height)
let detailFrame = CGRect(x: titleFrame.maxX + 8, y: eventGroup.minY,
                         width: CGFloat(detailWidth), height: eventGroup.height)
guard detailFrame.maxX + 8 == eventGroup.maxX,
      ceil((displayedTitle as NSString).size(withAttributes: [.font: titleFont]).width) <= titleFrame.width,
      ceil((detail as NSString).size(withAttributes: [.font: detailFont]).width) <= detailFrame.width else {
    FileHandle.standardError.write(Data("Calendar text padding or width budget failed\n".utf8))
    exit(1)
}
draw(displayedTitle, frame: titleFrame, font: titleFont,
     color: state == "event-hover" ? primary : accent, alignment: .left)
draw(detail, frame: detailFrame, font: detailFont,
     color: state == "event-hover" ? primary : muted, alignment: .left)

// The 116pt native-panel anchor stays exactly 58pt + 58pt.
draw("Thu Aug 6", frame: CGRect(x: dateGroup.minX + 1, y: dateGroup.minY, width: 54, height: 26),
     font: font("JetBrainsMonoNF-SemiBold", 9), color: state == "date-hover" ? primary : muted, alignment: .right)
draw("9:30 PM", frame: CGRect(x: dateGroup.minX + 61, y: dateGroup.minY, width: 53, height: 26),
     font: font("JetBrainsMonoNF-Medium", 9), color: state == "date-hover" ? primary : accent, alignment: .left)
let controlGlyphs = ["󰄨", "", "󰍬", "󰕾", "󰂯", "󰤨"]
for (index, glyph) in controlGlyphs.enumerated() {
    let foreground = (state == "system-hover" && index == 0) || index == controlGlyphs.count - 1 ? primary : muted
    draw(glyph, frame: CGRect(x: systemGroup.minX + CGFloat(index * 28), y: systemGroup.minY, width: 28, height: 26),
         font: font("JetBrainsMonoNF-Regular", index == controlGlyphs.count - 1 ? 12 : 14),
         color: foreground, alignment: .center)
}
image.unlockFocus()

guard let data = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: data) else { exit(1) }
let backingScale = CGFloat(bitmap.pixelsWide) / size.width
func pixel(_ x: CGFloat, _ y: CGFloat) -> NSColor? {
    bitmap.colorAt(x: Int(x * backingScale), y: Int(y * backingScale))
}
guard let eventPixel = pixel(eventGroup.minX + 2, eventGroup.midY),
      let seamLeft = pixel(eventGroup.maxX - 0.5, eventGroup.midY),
      let seamRight = pixel(dateGroup.minX + 0.5, dateGroup.midY),
      let datePixel = pixel(dateGroup.maxX - 2, dateGroup.midY),
      let systemPixel = pixel(systemGroup.maxX - 2, systemGroup.midY),
      eventPixel.alphaComponent > 0.9,
      seamLeft.alphaComponent > 0.9,
      seamRight.alphaComponent > 0.9,
      datePixel.alphaComponent > 0.9,
      systemPixel.alphaComponent > 0.9,
      let png = bitmap.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("Calendar continuous surface pixels failed\n".utf8))
    exit(1)
}
try png.write(to: URL(fileURLWithPath: output), options: .atomic)
print("Calendar bar synthetic renderer passed")
