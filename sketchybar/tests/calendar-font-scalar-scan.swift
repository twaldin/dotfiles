import AppKit
import CoreText
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard CommandLine.arguments.count == 2 else { fail("Calendar scalar scan requires the config root") }
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
func read(_ relative: String) -> String {
    let url = root.appendingPathComponent(relative)
    guard let value = try? String(contentsOf: url, encoding: .utf8) else { fail("Calendar scalar scan source missing") }
    return value
}
func section(_ name: String, in source: String) -> String {
    let marker = name + " = {"
    guard let start = source.range(of: marker)?.upperBound,
          let end = source.range(of: "\n  },", range: start..<source.endIndex)?.lowerBound else {
        fail("Calendar scalar scan range section changed")
    }
    return String(source[start..<end])
}
func hexRanges(_ body: String) -> [ClosedRange<UInt32>] {
    let expression = try! NSRegularExpression(pattern: "0x([0-9a-fA-F]+)")
    let ns = body as NSString
    let values = expression.matches(in: body, range: NSRange(location: 0, length: ns.length)).compactMap { match -> UInt32? in
        UInt32(ns.substring(with: match.range(at: 1)), radix: 16)
    }
    guard !values.isEmpty, values.count % 2 == 0 else { fail("Calendar scalar scan range shape changed") }
    return stride(from: 0, to: values.count, by: 2).map { values[$0]...values[$0 + 1] }
}
func contains(_ value: UInt32, _ ranges: [ClosedRange<UInt32>]) -> Bool {
    var low = 0
    var high = ranges.count - 1
    while low <= high {
        let middle = (low + high) / 2
        if value < ranges[middle].lowerBound { high = middle - 1 }
        else if value > ranges[middle].upperBound { low = middle + 1 }
        else { return true }
    }
    return false
}
func number(_ name: String, in source: String) -> CGFloat {
    let expression = try! NSRegularExpression(pattern: "\\b" + NSRegularExpression.escapedPattern(for: name) + "\\s*=\\s*([0-9.]+)")
    let ns = source as NSString
    guard let match = expression.firstMatch(in: source, range: NSRange(location: 0, length: ns.length)),
          let value = Double(ns.substring(with: match.range(at: 1))) else { fail("Calendar scalar scan constant changed") }
    return CGFloat(value)
}
func stringValue(_ name: String, in source: String) -> String {
    let expression = try! NSRegularExpression(pattern: "\\b" + NSRegularExpression.escapedPattern(for: name) + "\\s*=\\s*\"([^\"]+)\"")
    let ns = source as NSString
    guard let match = expression.firstMatch(in: source, range: NSRange(location: 0, length: ns.length)) else { fail("Calendar scalar scan font changed") }
    return ns.substring(with: match.range(at: 1))
}

let scalarProcess = Process()
scalarProcess.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/lua")
scalarProcess.arguments = [root.appendingPathComponent("tests/calendar-safe-scalar-ranges.lua").path]
var scalarEnvironment = ProcessInfo.processInfo.environment
scalarEnvironment["SKETCHYBAR_CONFIG_DIR"] = root.path
scalarProcess.environment = scalarEnvironment
let scalarOutput = Pipe()
scalarProcess.standardOutput = scalarOutput
scalarProcess.standardError = Pipe()
do { try scalarProcess.run() } catch { fail("Calendar safe-scalar source failed to start") }
scalarProcess.waitUntilExit()
guard scalarProcess.terminationStatus == 0,
      let scalarText = String(data: scalarOutput.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else {
    fail("Calendar safe-scalar source failed")
}
let reachableRanges = hexRanges(scalarText)
let widthRangesSource = read("lib/calendar_width_ranges.lua")
let expectedOversizedRanges = hexRanges(section("oversized", in: widthRangesSource))
let expectedOversized = Set(expectedOversizedRanges.flatMap { Array($0) })
let layout = read("lib/calendar_bar_layout.lua")
let fallbackAdvance = number("title_fallback_advance", in: layout)
let oversizedAdvance = number("title_oversized_advance", in: layout)
let fontName = stringValue("title_font_postscript", in: layout)
let fontSize = number("title_font_size", in: layout)

// The maximum of path bounds and typographic advance composes safely when
// CoreText positions multiple shaped scalars in one dynamic text lane.
func scalarWidthBound(_ scalar: Unicode.Scalar, _ font: NSFont) -> CGFloat {
    let attributed = NSAttributedString(string: String(scalar), attributes: [.font: font])
    let line = CTLineCreateWithAttributedString(attributed)
    let pathWidth = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds).width
    let advanceWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    return max(pathWidth, advanceWidth)
}

guard let font = NSFont(name: fontName, size: fontSize) else { fail("Calendar scalar scan font unavailable") }
var actualOversized = Set<UInt32>()
var maximum = CGFloat.zero
var violation = false
for raw in 0..<0x110000 {
    let value = UInt32(raw)
    if !contains(value, reachableRanges) { continue }
    guard let scalar = Unicode.Scalar(value) else { continue }
    let width = scalarWidthBound(scalar, font)
    maximum = max(maximum, width)
    if width > fallbackAdvance { actualOversized.insert(value) }
    let allowed = expectedOversized.contains(value) ? oversizedAdvance : fallbackAdvance
    if width > allowed { violation = true }
}
if !actualOversized.isSubset(of: expectedOversized) { fail("Calendar oversized scalar table does not cover the complete CoreText scan") }
if violation { fail("Calendar scalar advance is below a reachable CoreText glyph width") }
if !expectedOversized.contains(0xFDFD) { fail("Calendar Arabic ligature regression scalar missing") }
if maximum > oversizedAdvance { fail("Calendar oversized advance is below the complete CoreText maximum") }
print("Calendar complete sanitizer-reachable scalar width scan passed")
