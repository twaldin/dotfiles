import AppKit
import CoreText
import Foundation

guard let detailFont = NSFont(name: "JetBrainsMonoNF-Medium", size: 8),
      let titleFont = NSFont(name: "JetBrainsMonoNF-SemiBold", size: 9),
      let dateFont = NSFont(name: "JetBrainsMonoNF-SemiBold", size: 9),
      let clockFont = NSFont(name: "JetBrainsMonoNF-Medium", size: 9) else {
    FileHandle.standardError.write(Data("Required exact calendar font faces are unavailable\n".utf8))
    exit(1)
}
let requiredFaces = [
    (detailFont, "JetBrainsMonoNF-Medium"),
    (titleFont, "JetBrainsMonoNF-SemiBold"),
    (dateFont, "JetBrainsMonoNF-SemiBold"),
    (clockFont, "JetBrainsMonoNF-Medium"),
]
for (font, expectedName) in requiredFaces where font.fontName != expectedName {
    FileHandle.standardError.write(Data("Calendar font face substitution is prohibited\n".utf8))
    exit(1)
}
guard titleFont.coveredCharacterSet.contains(Unicode.Scalar(0xF00ED)!) else {
    FileHandle.standardError.write(Data("Required calendar glyph is unavailable\n".utf8))
    exit(1)
}

// Match SketchyBar v2.24.0 text.c: glyph-path bounds plus 1.5, truncated to UInt32.
func glyphPathWidth(_ text: String, font: NSFont) -> CGFloat {
    let attributed = NSAttributedString(string: text, attributes: [.font: font])
    let line = CTLineCreateWithAttributedString(attributed)
    return CTLineGetBoundsWithOptions(line, .useGlyphPathBounds).width
}
func sketchyWidth(_ text: String, font: NSFont) -> Int {
    Int(glyphPathWidth(text, font: font) + 1.5)
}

guard sketchyWidth("M", font: titleFont) == 5,
      sketchyWidth("M", font: detailFont) == 5,
      sketchyWidth("会", font: titleFont) == 10,
      sketchyWidth("🙂", font: titleFont) == 12 else {
    FileHandle.standardError.write(Data("Calendar source-faithful font widths changed\n".utf8))
    exit(1)
}
for value in 0x20...0x7E {
    let scalar = Unicode.Scalar(value)!
    let text = String(Character(scalar))
    if !titleFont.coveredCharacterSet.contains(scalar) || glyphPathWidth(text, font: titleFont) > 5.4 {
        FileHandle.standardError.write(Data("Calendar ASCII narrow allow-list changed\n".utf8))
        exit(1)
    }
}
guard glyphPathWidth("󰃭 ", font: titleFont) <= 10.8,
      glyphPathWidth("…", font: titleFont) <= 5.4 else {
    FileHandle.standardError.write(Data("Calendar trusted prefix or ellipsis width changed\n".utf8))
    exit(1)
}

guard let root = ProcessInfo.processInfo.environment["SKETCHYBAR_CONFIG_DIR"] else {
    FileHandle.standardError.write(Data("SKETCHYBAR_CONFIG_DIR is required\n".utf8))
    exit(1)
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/lua")
process.arguments = [root + "/tests/calendar-title-layout-fixtures.lua"]
var environment = ProcessInfo.processInfo.environment
environment["SKETCHYBAR_CONFIG_DIR"] = root
process.environment = environment
let output = Pipe()
process.standardOutput = output
process.standardError = Pipe()
do { try process.run() } catch {
    FileHandle.standardError.write(Data("Calendar Lua layout fixture failed to start\n".utf8))
    exit(1)
}
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("Calendar Lua layout fixture failed\n".utf8))
    exit(1)
}
let fields = output.fileHandleForReading.readDataToEndOfFile().split(separator: 0, omittingEmptySubsequences: false)
guard fields.last?.isEmpty == true, (fields.count - 1) % 8 == 0 else {
    FileHandle.standardError.write(Data("Calendar Lua layout fixture shape failed\n".utf8))
    exit(1)
}
var seen = Set<String>()
for offset in stride(from: 0, to: fields.count - 1, by: 8) {
    guard let name = String(data: fields[offset], encoding: .utf8),
          let input = String(data: fields[offset + 1], encoding: .utf8),
          let display = String(data: fields[offset + 2], encoding: .utf8),
          let detail = String(data: fields[offset + 3], encoding: .utf8),
          let overflow = String(data: fields[offset + 4], encoding: .utf8),
          let eventMaximumText = String(data: fields[offset + 5], encoding: .utf8),
          let edgeText = String(data: fields[offset + 6], encoding: .utf8),
          let gapText = String(data: fields[offset + 7], encoding: .utf8),
          let eventMaximum = Int(eventMaximumText),
          let edge = Int(edgeText),
          let gap = Int(gapText) else {
        FileHandle.standardError.write(Data("Calendar Lua layout fixture UTF-8 failed\n".utf8))
        exit(1)
    }
    seen.insert(name)
    let total = (2 * edge) + (detail.isEmpty ? 0 : gap)
        + sketchyWidth(display, font: titleFont)
        + (detail.isEmpty ? 0 : sketchyWidth(detail, font: detailFont))
    guard total <= eventMaximum else {
        FileHandle.standardError.write(Data("Calendar native Unicode layout exceeded shared maximum: \(name)\n".utf8))
        exit(1)
    }
    if overflow == "1" {
        guard display.hasSuffix("…"), display != "󰃭 " + input,
              display.unicodeScalars.count > 3 else {
            FileHandle.standardError.write(Data("Calendar bounded overflow ellipsis failed: \(name)\n".utf8))
            exit(1)
        }
    } else {
        guard display == "󰃭 " + input, !display.hasSuffix("…") else {
            FileHandle.standardError.write(Data("Calendar fitting title changed: \(name)\n".utf8))
            exit(1)
        }
    }
    if name == "japanese-combining" {
        let tail = Array(display.unicodeScalars.suffix(2)).map(\.value)
        if tail != [0x3099, 0x2026] {
            FileHandle.standardError.write(Data("Calendar Japanese combining cluster was split\n".utf8))
            exit(1)
        }
    }
    if name == "hangul-conjoining" {
        let tail = Array(display.unicodeScalars.suffix(2)).map(\.value)
        if tail != [0x11A8, 0x2026] {
            FileHandle.standardError.write(Data("Calendar Hangul conjoining cluster was split\n".utf8))
            exit(1)
        }
    }
    if name == "indic-conjoining" {
        let tail = Array(display.unicodeScalars.suffix(2)).map(\.value)
        if tail != [0x0937, 0x2026] {
            FileHandle.standardError.write(Data("Calendar Indic conjoining cluster was split\n".utf8))
            exit(1)
        }
    }
}
let requiredFixtures: Set<String> = ["ascii-fit", "ascii-overflow", "cjk-overflow", "emoji-overflow", "decomposed-fit", "indic-fit", "indic-conjoining", "dutch-overflow", "latin-fallback-overflow", "punctuation-overflow", "japanese-combining", "hangul-conjoining", "oversized-arabic", "cyrillic-overflow", "greek-overflow", "empty-detail"]
guard seen == requiredFixtures else {
    FileHandle.standardError.write(Data("Calendar Unicode fixture coverage changed\n".utf8))
    exit(1)
}

let detailSamples = [
    "in 8d · 99d+ ↗",
    "ends in 99d+ · 99d+ ↗",
    "ends in 23h59m · 23h59m ↗",
    "ends in 98d23h · 98d23h ↗",
    "time unavailable ↗",
    "all day ↗",
    "in 98d23h · all day ↗",
    "STALE",
]
for sample in detailSamples where sketchyWidth(sample, font: detailFont) > Int(ceil(Double(sample.unicodeScalars.count) * 4.8 + 1.5)) {
    FileHandle.standardError.write(Data("Calendar intrinsic detail budget failed\n".utf8))
    exit(1)
}
for sample in ["Wed Sep 30", "12:59 PM"] {
    let limit = sample.contains(":") ? 53 : 54
    let font = sample.contains(":") ? clockFont : dateFont
    if sketchyWidth(sample, font: font) > limit {
        FileHandle.standardError.write(Data("Calendar date/time width budget failed\n".utf8))
        exit(1)
    }
}
print("Calendar intrinsic Unicode font-width budgets passed")
