import AppKit
import Darwin
import Foundation
import CryptoKit

private enum Palette {
  static let surface = NSColor(calibratedRed: 0x18/255, green: 0x1b/255, blue: 0x1f/255, alpha: 1)
  static let surface2 = NSColor(calibratedRed: 0x23/255, green: 0x28/255, blue: 0x2d/255, alpha: 1)
  static let border = NSColor(calibratedRed: 0x34/255, green: 0x3a/255, blue: 0x40/255, alpha: 1)
  static let primary = NSColor(calibratedRed: 0xe8/255, green: 0xea/255, blue: 0xed/255, alpha: 1)
  static let normal = NSColor(calibratedRed: 0xc5/255, green: 0xc9/255, blue: 0xce/255, alpha: 1)
  static let muted = NSColor(calibratedRed: 0x88/255, green: 0x8e/255, blue: 0x96/255, alpha: 1)
  static let selected = NSColor(calibratedRed: 0xb8/255, green: 0xc0/255, blue: 0xca/255, alpha: 1)
}

struct DayValue: Hashable {
  let year: Int
  let month: Int
  let day: Int
  var key: String { String(format: "%04d-%02d-%02d", year, month, day) }
}

struct MonthCell {
  let date: DayValue
  let isInMonth: Bool
}

enum CalendarMath {
  static let supportedYears = 1900...2200
  private static let representableYears = 1899...2201
  static var calendar: Calendar = {
    var value = Calendar(identifier: .gregorian)
    value.timeZone = .current
    return value
  }()

  static func shifted(year: Int, month: Int, by delta: Int) -> (Int, Int) {
    let minimum = supportedYears.lowerBound * 12
    let maximum = supportedYears.upperBound * 12 + 11
    let value = min(max(year * 12 + month - 1 + delta, minimum), maximum)
    return (value / 12, value % 12 + 1)
  }

  static func isValid(_ value: DayValue) -> Bool {
    guard representableYears.contains(value.year), (1...12).contains(value.month), (1...31).contains(value.day),
          let date = calendar.date(from: DateComponents(year: value.year, month: value.month, day: value.day, hour: 12)) else { return false }
    return self.value(date) == value
  }

  static func date(_ value: DayValue) -> Date {
    precondition(isValid(value), "Unsupported calendar date")
    return calendar.date(from: DateComponents(year: value.year, month: value.month, day: value.day, hour: 12))!
  }

  static func value(_ date: Date) -> DayValue {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return DayValue(year: parts.year!, month: parts.month!, day: parts.day!)
  }

  static func daysInMonth(year: Int, month: Int) -> Int {
    calendar.range(of: .day, in: .month, for: date(DayValue(year: year, month: month, day: 1)))!.count
  }

  static func cells(year: Int, month: Int) -> [MonthCell] {
    let first = date(DayValue(year: year, month: month, day: 1))
    let weekday = calendar.component(.weekday, from: first) - 1
    let start = calendar.date(byAdding: .day, value: -weekday, to: first)!
    return (0..<42).map { offset in
      let current = value(calendar.date(byAdding: .day, value: offset, to: start)!)
      return MonthCell(date: current, isInMonth: current.year == year && current.month == month)
    }
  }

  static func isPast(_ value: DayValue, now: Date = Date()) -> Bool {
    let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date(value)))!
    return end <= now
  }
}

private enum CalendarText {
  static func sanitize(_ raw: String?, maxGraphemes: Int, maxBytes: Int) -> String? {
    guard let raw else { return nil }
    var scalars = String.UnicodeScalarView()
    scalars.reserveCapacity(min(raw.unicodeScalars.count, maxBytes))
    for scalar in raw.unicodeScalars {
      switch scalar.properties.generalCategory {
      case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .surrogate:
        scalars.append(" ")
      default:
        scalars.append(scalar)
      }
    }
    let collapsed = String(scalars).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
    var result = ""
    var graphemes = 0
    var bytes = 0
    for character in collapsed {
      let value = String(character)
      let count = value.utf8.count
      if graphemes >= maxGraphemes || bytes + count > maxBytes { break }
      result.append(character)
      graphemes += 1
      bytes += count
    }
    return result.isEmpty ? nil : result
  }

  static func title(_ raw: String?) -> String? { sanitize(raw, maxGraphemes: 256, maxBytes: 1024) }
  static func property(_ raw: String?) -> String? { sanitize(raw, maxGraphemes: 2048, maxBytes: 8192) }
  static func uid(_ raw: String?) -> String? { sanitize(raw, maxGraphemes: 512, maxBytes: 2048) }
  static func sortKey(_ value: String) -> String {
    value.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
  }
}

private enum OccurrenceIdentity {
  static func value(uid: String, start: Date) -> String {
    let millis = Int64((start.timeIntervalSince1970 * 1000).rounded())
    let digest = SHA256.hash(data: Data("\(uid)\u{0}\(millis)".utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}

enum EventPhase: String {
  case ended = "ENDED"
  case ongoing = "ONGOING"
  case upcoming = "UPCOMING"

  static func value(for event: EventOccurrence, now: Date) -> EventPhase {
    if event.end <= now { return .ended }
    if event.start <= now { return .ongoing }
    return .upcoming
  }
}

struct EventOccurrence {
  let identity: String
  let title: String
  let start: Date
  let end: Date
  let allDay: Bool
  let meetingURL: URL?

  init(uid: String, title: String, start: Date, end: Date, allDay: Bool, meetingURL: URL?) {
    self.identity = OccurrenceIdentity.value(uid: uid, start: start)
    self.title = title
    self.start = start
    self.end = end
    self.allDay = allDay
    self.meetingURL = meetingURL
  }

  var duration: TimeInterval {
    if allDay {
      let days = CalendarMath.calendar.dateComponents([.day], from: CalendarMath.calendar.startOfDay(for: start), to: CalendarMath.calendar.startOfDay(for: end)).day ?? 0
      return TimeInterval(max(0, days) * 86400)
    }
    return max(0, end.timeIntervalSince(start))
  }
}

private struct FixtureOccurrence: Codable {
  let uid: String
  let title: String
  let allDay: Bool
  let start: String?
  let end: String?
  let url: String?
  let location: String?
  let notes: String?
}

private struct FixtureDay: Codable {
  let state: String?
  let delayMS: Int?
  let events: [FixtureOccurrence]?
}

private struct FixtureDocument: Codable {
  let schemaVersion: Int
  let days: [String: FixtureDay]
}

final class GenerationGate {
  private(set) var value = 0
  func begin() -> Int { value += 1; return value }
  func accepts(_ candidate: Int) -> Bool { candidate == value }
}

enum EventQueryResult {
  case events([EventOccurrence])
  case empty
  case error
  case permission
  case malformed
}

enum EventProviderError: Error { case invalidFixture }
private enum EventParseError: Error { case malformed }

private enum EventOrdering {
  static func sorted(_ values: [EventOccurrence]) -> [EventOccurrence] {
    values.sorted {
      if $0.allDay != $1.allDay { return $0.allDay && !$1.allDay }
      if !$0.allDay {
        if $0.start != $1.start { return $0.start < $1.start }
        if $0.end != $1.end { return $0.end < $1.end }
      }
      let leftTitle = CalendarText.sortKey($0.title)
      let rightTitle = CalendarText.sortKey($1.title)
      if leftTitle != rightTitle { return leftTitle < rightTitle }
      return $0.identity < $1.identity
    }
  }
}

private enum MeetingLink {
  static func safe(_ rawValue: String?) -> URL? {
    guard var value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
    value = value.replacingOccurrences(of: "&amp;", with: "&")
    guard value.utf8.count <= 4096 else { return nil }
    while let last = value.last, ".,)]}".contains(last) { value.removeLast() }
    guard let components = URLComponents(string: value), components.scheme?.lowercased() == "https",
          components.user == nil, components.password == nil,
          let hostValue = components.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")),
          !hostValue.isEmpty, components.port == nil || components.port == 443 else { return nil }
    let path = components.percentEncodedPath.lowercased()
    let zoom = (hostValue == "zoom.us" || hostValue.hasSuffix(".zoom.us")) &&
      (path.range(of: #"^/[jsw]/[0-9]+"#, options: .regularExpression) != nil ||
       path.range(of: #"^/wc/(?:join|[0-9]+)/[0-9]+"#, options: .regularExpression) != nil ||
       path.range(of: #"^/my/[a-z0-9._-]+"#, options: .regularExpression) != nil)
    let meet = hostValue == "meet.google.com" &&
      path.range(of: #"^/[a-z]{3}-[a-z]{4}-[a-z]{3}(?:/|$)"#, options: .regularExpression) != nil
    let teams = ["teams.microsoft.com", "teams.live.com", "teams.microsoft.us"].contains(hostValue) &&
      (path.hasPrefix("/l/meetup-join/") || path.hasPrefix("/meet/"))
    let webex = (hostValue == "webex.com" || hostValue.hasSuffix(".webex.com")) &&
      (path.hasPrefix("/meet/") || path.hasPrefix("/join/") ||
       path.range(of: #"^/webappng/sites/.+/meeting/"#, options: .regularExpression) != nil)
    guard zoom || meet || teams || webex else { return nil }
    return components.url
  }

  static func candidates(in value: String?) -> [String] {
    guard let value else { return [] }
    let expression = try! NSRegularExpression(pattern: "https?://[^\\s<>\\\"']+", options: [.caseInsensitive])
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    return expression.matches(in: value, range: range).compactMap {
      Range($0.range, in: value).map { String(value[$0]) }
    }
  }

  static func best(explicit: String?, location: String?, notes: String?) -> URL? {
    if let direct = safe(explicit) { return direct }
    for text in [notes, location] {
      for candidate in candidates(in: text) {
        if let safe = safe(candidate) { return safe }
      }
    }
    return nil
  }
}

private struct OutputTokens {
  let record: String
  let property: String
  let newline: String

  static func random() -> OutputTokens {
    let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    return OutputTokens(record: "__SB_REC_\(nonce)__", property: "__SB_PROP_\(nonce)__", newline: "__SB_NL_\(nonce)__")
  }
}

private enum EventOutputParser {
  static let maximumOutputBytes = 1_048_576
  static let maximumRecords = 512
  static let maximumRawPropertyBytes = 16_384
  static let maximumRawRecordBytes = 65_536

  static func decode(_ data: Data) -> String? {
    guard data.count <= maximumOutputBytes else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private static func makeDateFormatter() -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.isLenient = false
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
    return formatter
  }

  private static func trimmed(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func matches(_ pattern: String, _ value: String) -> [String]? {
    let expression = try! NSRegularExpression(pattern: pattern)
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    guard let match = expression.firstMatch(in: value, range: range), match.range == range else { return nil }
    return (1..<match.numberOfRanges).map { index in
      let item = match.range(at: index)
      guard item.location != NSNotFound, let range = Range(item, in: value) else { return "" }
      return String(value[range])
    }
  }

  private static func parseDay(_ value: String) throws -> DayValue {
    guard let fields = matches(#"^([0-9]{4})-([0-9]{2})-([0-9]{2})$"#, value),
          let year = Int(fields[0]), let month = Int(fields[1]), let day = Int(fields[2]) else { throw EventParseError.malformed }
    let result = DayValue(year: year, month: month, day: day)
    guard CalendarMath.isValid(result) else { throw EventParseError.malformed }
    return result
  }

  private static func parseDateTime(_ value: String, selected: DayValue) throws -> (Date, Date, Bool) {
    if let fields = matches(#"^([0-9]{4}-[0-9]{2}-[0-9]{2})(?: - ([0-9]{4}-[0-9]{2}-[0-9]{2}))?$"#, value) {
      let startDay = try parseDay(fields[0])
      let localStart = CalendarMath.calendar.startOfDay(for: CalendarMath.date(startDay))
      let localEnd: Date
      if fields[1].isEmpty {
        localEnd = CalendarMath.calendar.date(byAdding: .day, value: 1, to: localStart)!
      } else {
        let endDay = try parseDay(fields[1])
        let inclusiveEnd = CalendarMath.calendar.startOfDay(for: CalendarMath.date(endDay))
        localEnd = CalendarMath.calendar.date(byAdding: .day, value: 1, to: inclusiveEnd)!
      }
      guard localEnd > localStart else { throw EventParseError.malformed }
      return (localStart, localEnd, true)
    }
    guard let fields = matches(#"^([0-9]{4}-[0-9]{2}-[0-9]{2}) at ([0-9]{2}:[0-9]{2}:[0-9]{2}) ([+-][0-9]{4}) - (?:(?:([0-9]{4}-[0-9]{2}-[0-9]{2})) at )?([0-9]{2}:[0-9]{2}:[0-9]{2}) ([+-][0-9]{4})$"#, value) else {
      throw EventParseError.malformed
    }
    _ = try parseDay(fields[0])
    let dateFormatter = makeDateFormatter()
    guard let start = dateFormatter.date(from: "\(fields[0]) \(fields[1]) \(fields[2])") else { throw EventParseError.malformed }
    let endDay = fields[3].isEmpty ? fields[0] : fields[3]
    _ = try parseDay(endDay)
    guard var end = dateFormatter.date(from: "\(endDay) \(fields[4]) \(fields[5])") else { throw EventParseError.malformed }
    if fields[3].isEmpty && end <= start { end = CalendarMath.calendar.date(byAdding: .day, value: 1, to: end)! }
    guard end > start else { throw EventParseError.malformed }
    return (start, end, false)
  }

  static func parse(_ output: String, selected: DayValue, tokens: OutputTokens) throws -> [EventOccurrence] {
    guard output.utf8.count <= maximumOutputBytes else { throw EventParseError.malformed }
    if trimmed(output).isEmpty { return [] }
    let records = output.components(separatedBy: tokens.record)
    guard records.first.map(trimmed)?.isEmpty == true, records.count > 1,
          records.count - 1 <= maximumRecords else { throw EventParseError.malformed }
    let interval = EventProvider.queryInterval(for: selected)
    var result: [EventOccurrence] = []
    var identities = Set<String>()
    for rawRecord in records.dropFirst() {
      let record = rawRecord.trimmingCharacters(in: .newlines)
      guard !trimmed(record).isEmpty else { throw EventParseError.malformed }
      guard record.utf8.count <= maximumRawRecordBytes else { throw EventParseError.malformed }
      let properties = record.components(separatedBy: tokens.property)
      guard properties.count >= 3, properties.allSatisfy({ $0.utf8.count <= maximumRawPropertyBytes }),
            let title = CalendarText.title(trimmed(properties[0])),
            !trimmed(properties[1]).isEmpty else { throw EventParseError.malformed }
      let parsed = try parseDateTime(trimmed(properties[1]), selected: selected)
      var url: String?
      var location: String?
      var notes: String?
      var uid: String?
      for (offset, rawProperty) in properties.dropFirst(2).enumerated() {
        guard rawProperty.utf8.count <= maximumRawPropertyBytes else { throw EventParseError.malformed }
        let property = trimmed(rawProperty).replacingOccurrences(of: tokens.newline, with: "\n")
        if property.hasPrefix("url: ") && url == nil && uid == nil { url = String(property.dropFirst(5)) }
        else if property.hasPrefix("location: ") && location == nil && uid == nil { location = String(property.dropFirst(10)) }
        else if property.hasPrefix("notes: ") && notes == nil && uid == nil { notes = String(property.dropFirst(7)) }
        else if property.hasPrefix("uid: ") && uid == nil && offset == properties.count - 3 {
          uid = CalendarText.uid(String(property.dropFirst(5)))
        } else { throw EventParseError.malformed }
      }
      guard let uid else { throw EventParseError.malformed }
      guard parsed.0 < interval.end && parsed.1 > interval.start else { continue }
      let meetingURL = MeetingLink.best(explicit: url, location: location, notes: notes)
      let event = EventOccurrence(uid: uid, title: title, start: parsed.0, end: parsed.1, allDay: parsed.2, meetingURL: meetingURL)
      guard identities.insert(event.identity).inserted else { throw EventParseError.malformed }
      result.append(event)
    }
    return EventOrdering.sorted(result)
  }

}

final class EventProvider {
  private let icalBuddy: String
  private let fixture: [String: FixtureDay]?
  private let executionTimeout: TimeInterval
  private let killGrace: TimeInterval
  private let prelaunchHook: (() -> Void)?
  private let beforeFixturePublish: (() -> Void)?
  private let lock = NSLock()
  private var currentID: UUID?
  private var currentProcess: Process?
  private var currentWork: DispatchWorkItem?
  private var stoppedPrelaunchPID: pid_t?

  init(icalBuddy: String, fixturePath: String?, executionTimeout: TimeInterval = 5.0, killGrace: TimeInterval = 0.25, prelaunchHook: (() -> Void)? = nil, beforeFixturePublish: (() -> Void)? = nil) throws {
    self.icalBuddy = icalBuddy
    self.executionTimeout = executionTimeout
    self.killGrace = killGrace
    self.prelaunchHook = prelaunchHook
    self.beforeFixturePublish = beforeFixturePublish
    if let fixturePath {
      guard let data = try? Data(contentsOf: URL(fileURLWithPath: fixturePath)), data.count <= 2_097_152,
            String(data: data, encoding: .utf8) != nil,
            let parsed = try? JSONDecoder().decode(FixtureDocument.self, from: data),
            parsed.schemaVersion == 1 else { throw EventProviderError.invalidFixture }
      fixture = parsed.days
    } else {
      fixture = nil
    }
  }

  func runningPIDForTests() -> pid_t? {
    lock.lock(); defer { lock.unlock() }
    guard let process = currentProcess, process.isRunning else { return nil }
    return process.processIdentifier
  }

  func stoppedPrelaunchPIDForTests() -> pid_t? {
    lock.lock(); defer { lock.unlock() }
    return stoppedPrelaunchPID
  }

  func cancelAndWaitForTests(timeout: TimeInterval = 0.5) {
    lock.lock(); let process = currentProcess; lock.unlock()
    cancel()
    guard let process else { return }
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline {
      RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(0.01)))
    }
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    let killDeadline = Date().addingTimeInterval(0.25)
    while process.isRunning && Date() < killDeadline {
      RunLoop.current.run(until: min(killDeadline, Date().addingTimeInterval(0.01)))
    }
  }

  private func stop(_ process: Process) {
    guard process.isRunning else { return }
    process.terminate()
    let pid = process.processIdentifier
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + killGrace) {
      if process.isRunning { kill(pid, SIGKILL) }
    }
  }

  func cancel() {
    lock.lock()
    currentID = nil
    let process = currentProcess
    currentProcess = nil
    let work = currentWork
    currentWork = nil
    lock.unlock()
    work?.cancel()
    if let process { stop(process) }
  }

  private static func fixtureOccurrence(_ value: FixtureOccurrence, selected: DayValue) throws -> EventOccurrence? {
    let dayStart = CalendarMath.calendar.startOfDay(for: CalendarMath.date(selected))
    let dayEnd = CalendarMath.calendar.date(byAdding: .day, value: 1, to: dayStart)!
    guard value.title.utf8.count <= EventOutputParser.maximumRawPropertyBytes,
          value.uid.utf8.count <= EventOutputParser.maximumRawPropertyBytes,
          let title = CalendarText.title(value.title), let uid = CalendarText.uid(value.uid) else { throw EventParseError.malformed }
    for property in [value.url, value.location, value.notes].compactMap({ $0 }) {
      guard property.utf8.count <= EventOutputParser.maximumRawPropertyBytes else { throw EventParseError.malformed }
    }
    let meetingURL = MeetingLink.best(explicit: value.url, location: value.location, notes: value.notes)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
    if value.allDay {
      if value.start == nil && value.end == nil {
        return EventOccurrence(uid: uid, title: title, start: dayStart, end: dayEnd, allDay: true, meetingURL: meetingURL)
      }
      guard let startValue = value.start, let endValue = value.end,
            let start = formatter.date(from: startValue), let end = formatter.date(from: endValue), end > start else { throw EventParseError.malformed }
      guard start < dayEnd && end > dayStart else { return nil }
      return EventOccurrence(uid: uid, title: title, start: start, end: end, allDay: true, meetingURL: meetingURL)
    }
    guard let startValue = value.start, let endValue = value.end,
          let start = formatter.date(from: startValue), let end = formatter.date(from: endValue),
          end > start else { throw EventParseError.malformed }
    guard start < dayEnd && end > dayStart else { return nil }
    return EventOccurrence(uid: uid, title: title, start: start, end: end, allDay: false, meetingURL: meetingURL)
  }

  private static func drain(_ handle: FileHandle, limit: Int) -> (data: Data, overflow: Bool) {
    var data = Data()
    var overflow = false
    while true {
      let chunk = handle.readData(ofLength: 65_536)
      if chunk.isEmpty { break }
      if data.count + chunk.count <= limit { data.append(chunk) } else { overflow = true }
    }
    return (data, overflow)
  }

  static func queryInterval(for date: DayValue) -> (start: Date, end: Date) {
    let start = CalendarMath.calendar.startOfDay(for: CalendarMath.date(date))
    let end = CalendarMath.calendar.date(byAdding: .day, value: 1, to: start)!
    return (start, end)
  }

  private func publish(_ result: EventQueryResult, id: UUID, completion: @escaping (EventQueryResult) -> Void) {
    DispatchQueue.main.async {
      self.lock.lock(); let stillAccepted = self.currentID == id; self.lock.unlock()
      guard stillAccepted else { return }
      completion(result)
    }
  }

  func query(_ date: DayValue, completion: @escaping (EventQueryResult) -> Void) {
    cancel()
    let id = UUID()
    lock.lock(); currentID = id; lock.unlock()

    if let fixture {
      let day = fixture[date.key]
      let work = DispatchWorkItem { [weak self] in
        guard let self else { return }
        self.lock.lock(); let current = self.currentID == id; self.lock.unlock()
        guard current else { return }
        let result: EventQueryResult
        switch day?.state {
        case "error": result = .error
        case "permission": result = .permission
        case "malformed": result = .malformed
        default:
          do {
            guard (day?.events ?? []).count <= EventOutputParser.maximumRecords else { throw EventParseError.malformed }
            let values = try (day?.events ?? []).compactMap { try Self.fixtureOccurrence($0, selected: date) }
            let identities = Set(values.map(\.identity))
            guard identities.count == values.count else { throw EventParseError.malformed }
            let sorted = EventOrdering.sorted(values)
            result = sorted.isEmpty ? .empty : .events(sorted)
          } catch { result = .malformed }
        }
        self.beforeFixturePublish?()
        self.publish(result, id: id, completion: completion)
      }
      lock.lock(); currentWork = work; lock.unlock()
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(day?.delayMS ?? 0), execute: work)
      return
    }

    let executable = icalBuddy
    let tokens = OutputTokens.random()
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.lock.lock(); let current = self.currentID == id; self.lock.unlock()
      guard current else { return }
      let interval = Self.queryInterval(for: date)
      let start = interval.start
      let end = interval.end
      let queryFormatter = DateFormatter()
      queryFormatter.locale = Locale(identifier: "en_US_POSIX")
      queryFormatter.calendar = Calendar(identifier: .gregorian)
      queryFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
      let process = Process()
      process.executableURL = URL(fileURLWithPath: executable)
      process.arguments = [
        "-uid", "-nc", "-nrd", "-cf", "", "-tf", "%H:%M:%S %z", "-df", "%Y-%m-%d",
        "-po", "title,datetime,url,location,notes",
        // iCalBuddy treats the first and last -ps characters as separator-list delimiters;
        // output contains the random token without these pipe delimiters.
        "-ps", "|\(tokens.property)|",
        "-b", tokens.record, "-ss", "", "-nnr", tokens.newline,
        "-iep", "title,datetime,url,location,notes",
        "eventsFrom:\(queryFormatter.string(from: start))", "to:\(queryFormatter.string(from: end))",
      ]
      let output = Pipe()
      let errors = Pipe()
      process.standardOutput = output
      process.standardError = errors
      self.lock.lock()
      guard self.currentID == id else { self.lock.unlock(); return }
      self.currentProcess = process
      self.lock.unlock()
      self.prelaunchHook?()
      do {
        try process.run()
      } catch {
        self.lock.lock(); let accepted = self.currentID == id
        if self.currentProcess === process { self.currentProcess = nil }
        self.lock.unlock()
        if accepted { self.publish(.error, id: id, completion: completion) }
        return
      }
      self.lock.lock(); let ownsLaunch = self.currentID == id && self.currentProcess === process; self.lock.unlock()
      if !ownsLaunch {
        self.stop(process)
        process.waitUntilExit()
        self.lock.lock(); self.stoppedPrelaunchPID = process.processIdentifier
        if self.currentProcess === process { self.currentProcess = nil }
        self.lock.unlock()
        return
      }
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + self.executionTimeout) { [weak self, weak process] in
        guard let self, let process else { return }
        self.lock.lock(); let shouldStop = self.currentID == id && self.currentProcess === process; self.lock.unlock()
        if shouldStop { self.stop(process) }
      }
      let readGroup = DispatchGroup()
      let readLock = NSLock()
      var outputData = Data()
      var errorData = Data()
      var outputOverflow = false
      var errorOverflow = false
      readGroup.enter()
      DispatchQueue.global(qos: .utility).async {
        let value = Self.drain(output.fileHandleForReading, limit: EventOutputParser.maximumOutputBytes)
        readLock.lock(); outputData = value.data; outputOverflow = value.overflow; readLock.unlock(); readGroup.leave()
      }
      readGroup.enter()
      DispatchQueue.global(qos: .utility).async {
        let value = Self.drain(errors.fileHandleForReading, limit: 65_536)
        readLock.lock(); errorData = value.data; errorOverflow = value.overflow; readLock.unlock(); readGroup.leave()
      }
      process.waitUntilExit()
      readGroup.wait()
      self.lock.lock()
      let accepted = self.currentID == id
      if self.currentProcess === process { self.currentProcess = nil }
      self.lock.unlock()
      guard accepted else { return }
      guard process.terminationStatus == 0 else {
        let diagnostic = errorOverflow ? "" : (String(data: errorData, encoding: .utf8)?.lowercased() ?? "")
        let denied = diagnostic.contains("permission") || diagnostic.contains("authoriz") || diagnostic.contains("access denied")
        self.publish(denied ? .permission : .error, id: id, completion: completion)
        return
      }
      let result: EventQueryResult
      do {
        guard !outputOverflow, let text = EventOutputParser.decode(outputData) else { throw EventParseError.malformed }
        let events = try EventOutputParser.parse(text, selected: date, tokens: tokens)
        result = events.isEmpty ? .empty : .events(events)
      } catch { result = .malformed }
      self.publish(result, id: id, completion: completion)
    }
    lock.lock(); currentWork = work; lock.unlock()
    DispatchQueue.global(qos: .utility).async(execute: work)
  }
}

class FlatButton: NSButton {
  var handler: (() -> Void)?
  private var tracking: NSTrackingArea?

  init(title: String) {
    super.init(frame: .zero)
    self.title = title
    isBordered = false
    bezelStyle = .regularSquare
    setButtonType(.momentaryChange)
    font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
    contentTintColor = Palette.normal
    wantsLayer = true
    layer?.cornerRadius = 6
    target = self
    action = #selector(invoke)
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    focusRingType = .default
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  override var acceptsFirstResponder: Bool { true }
  override var canBecomeKeyView: Bool { true }
  override var needsPanelToBecomeKey: Bool { true }
  override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 2, dy: 2) }
  override func drawFocusRingMask() {
    NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 4, yRadius: 4).fill()
  }
  override func becomeFirstResponder() -> Bool {
    let accepted = super.becomeFirstResponder()
    if accepted { needsDisplay = true }
    return accepted
  }
  override func resignFirstResponder() -> Bool {
    let accepted = super.resignFirstResponder()
    if accepted { needsDisplay = true }
    return accepted
  }

  @objc private func invoke() { handler?() }

  override func updateTrackingAreas() {
    if let tracking { removeTrackingArea(tracking) }
    let value = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
    addTrackingArea(value)
    tracking = value
    super.updateTrackingAreas()
  }

  override func mouseEntered(with event: NSEvent) { layer?.backgroundColor = Palette.surface2.cgColor }
  override func mouseExited(with event: NSEvent) { layer?.backgroundColor = NSColor.clear.cgColor }
}

final class DateButton: FlatButton {
  var representedDate = DayValue(year: 1970, month: 1, day: 1)
  private(set) var selectedForAccessibility = false
  private let marker = CALayer()

  override init(title: String) {
    super.init(title: title)
    setAccessibilityRole(.radioButton)
    marker.cornerRadius = 1
    layer?.addSublayer(marker)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  override func layout() {
    super.layout()
    marker.frame = CGRect(x: bounds.midX - marker.bounds.width / 2, y: 3, width: marker.bounds.width, height: 2)
  }

  func configure(cell: MonthCell, today: DayValue, selected: DayValue) {
    representedDate = cell.date
    title = String(cell.date.day)
    let isToday = cell.date == today
    let isSelected = cell.date == selected
    contentTintColor = isSelected ? Palette.selected : (isToday ? Palette.primary : (cell.isInMonth ? Palette.normal : Palette.muted))
    font = NSFont.monospacedSystemFont(ofSize: 11, weight: (isToday || isSelected) ? .bold : .regular)
    marker.backgroundColor = isSelected ? Palette.selected.cgColor : (isToday ? Palette.muted.cgColor : NSColor.clear.cgColor)
    marker.bounds.size = CGSize(width: isSelected ? 12 : (isToday ? 3 : 0), height: 2)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "EEEE, MMMM d, yyyy"
    var states: [String] = []
    if isSelected { states.append("selected") }
    if isToday { states.append("today") }
    if !cell.isInMonth { states.append("outside current month") }
    let suffix = states.isEmpty ? "" : ", " + states.joined(separator: ", ")
    setAccessibilityLabel(formatter.string(from: CalendarMath.date(cell.date)) + suffix)
    selectedForAccessibility = isSelected
    setAccessibilityValue(NSNumber(value: isSelected))
    setAccessibilityHelp("Select this calendar date")
    needsLayout = true
  }
}

final class CalendarWindow: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
  override func cancelOperation(_ sender: Any?) { close() }
}

protocol CalendarOpening: AnyObject {
  func openURL(_ url: URL) -> Bool
  func openCalendar()
}

final class WorkspaceCalendarOpener: CalendarOpening {
  func openURL(_ url: URL) -> Bool { NSWorkspace.shared.open(url) }
  func openCalendar() {
    NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Calendar.app"), configuration: NSWorkspace.OpenConfiguration())
  }
}

private final class RecordingCalendarOpener: CalendarOpening {
  var URLResults: [Bool]
  private(set) var URLs: [URL] = []
  private(set) var calendarCount = 0
  init(URLResults: [Bool]) { self.URLResults = URLResults }
  func openURL(_ url: URL) -> Bool {
    URLs.append(url)
    return URLResults.isEmpty ? false : URLResults.removeFirst()
  }
  func openCalendar() { calendarCount += 1 }
}

private enum EventActionRouter {
  static func perform(_ event: EventOccurrence, opener: CalendarOpening) {
    if let meeting = event.meetingURL, opener.openURL(meeting) { return }
    opener.openCalendar()
  }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

final class EventRowButton: FlatButton {
  let titleLabel = NSTextField(labelWithString: "")
  let detailLabel = NSTextField(labelWithString: "")
  let meetingLabel = NSTextField(labelWithString: "↗")
  var occurrence: EventOccurrence?

  override init(title: String = "") {
    super.init(title: "")
    titleLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
    titleLabel.textColor = Palette.primary
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.maximumNumberOfLines = 1
    titleLabel.setAccessibilityElement(false)
    detailLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    detailLabel.textColor = Palette.muted
    detailLabel.alignment = .right
    detailLabel.lineBreakMode = .byClipping
    detailLabel.setAccessibilityElement(false)
    meetingLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
    meetingLabel.textColor = Palette.muted
    meetingLabel.alignment = .right
    meetingLabel.setAccessibilityElement(false)
    meetingLabel.toolTip = "Open secure meeting link"
    addSubview(titleLabel)
    addSubview(detailLabel)
    addSubview(meetingLabel)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  override func layout() {
    super.layout()
    titleLabel.frame = CGRect(x: 8, y: 3, width: max(0, bounds.width - 42), height: 18)
    meetingLabel.frame = CGRect(x: max(8, bounds.width - 28), y: 3, width: 20, height: 18)
    detailLabel.frame = CGRect(x: 8, y: 23, width: max(0, bounds.width - 16), height: 16)
  }

  func scrollIntoViewForKeyboardFocus() { scrollToVisible(bounds) }

  override func becomeFirstResponder() -> Bool {
    let accepted = super.becomeFirstResponder()
    if accepted { scrollIntoViewForKeyboardFocus() }
    return accepted
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    // NSView.hitTest receives a point in the receiver's superview coordinates
    // (unlike UIView); convert once before checking this row's local bounds.
    bounds.contains(convert(point, from: superview)) ? self : nil
  }

  func configure(_ value: EventOccurrence, detail: String, accessibilityDetail: String) {
    occurrence = value
    titleLabel.stringValue = value.title
    detailLabel.stringValue = detail
    meetingLabel.isHidden = value.meetingURL == nil
    meetingLabel.toolTip = value.meetingURL == nil ? nil : "Open secure meeting link"
    setAccessibilityIdentifier("calendar.event.\(value.identity)")
    let action = value.meetingURL == nil ? "Open in Calendar." : "Open secure meeting link."
    setAccessibilityLabel("\(value.title). \(accessibilityDetail) \(action)")
    setAccessibilityHelp(action)
    toolTip = value.title
  }
}

protocol AccessibilityNotificationPosting: AnyObject {
  func created(_ element: Any)
  func layoutChanged(_ group: Any, elements: [Any])
  func valueChanged(_ element: Any)
}

final class WorkspaceAccessibilityNotifier: AccessibilityNotificationPosting {
  func created(_ element: Any) { NSAccessibility.post(element: element, notification: .created) }
  func layoutChanged(_ group: Any, elements: [Any]) {
    NSAccessibility.post(element: group, notification: .layoutChanged, userInfo: [.uiElements: elements])
  }
  func valueChanged(_ element: Any) { NSAccessibility.post(element: element, notification: .valueChanged) }
}

private final class RecordingAccessibilityNotifier: AccessibilityNotificationPosting {
  private(set) var createdCount = 0
  private(set) var layoutCount = 0
  private(set) var lastElementCount = 0
  private(set) var valueChangedCount = 0
  func created(_ element: Any) { createdCount += 1 }
  func layoutChanged(_ group: Any, elements: [Any]) { layoutCount += 1; lastElementCount = elements.count }
  func valueChanged(_ element: Any) { valueChangedCount += 1 }
}

final class CalendarPanelController: NSObject, NSWindowDelegate {
  static let panelSize = CGSize(width: 300, height: 368)
  static let maximumPreferredHeight: CGFloat = 720
  private static let fixedTopHeight: CGFloat = 306
  let panel: CalendarWindow
  let content: NSView
  let provider: EventProvider
  let gate = GenerationGate()
  let monthButton = FlatButton(title: "")
  let selectedTitle = NSTextField(labelWithString: "")
  let grid: NSGridView
  let weekdayGrid: NSGridView
  let dateButtons: [DateButton]
  let weekdayLabels: [NSTextField]
  let scrollView = NSScrollView(frame: .zero)
  let eventDocument = FlippedView(frame: .zero)
  var navButtons: [FlatButton] = []
  var eventRows: [EventRowButton] = []
  var detailLabels: [NSTextField] = []
  let hostAnchor: CGRect
  let displayFrame: CGRect
  let opener: CalendarOpening
  let accessibilityNotifier: AccessibilityNotificationPosting
  let injectedNow: Date?
  var viewYear: Int
  var viewMonth: Int
  var selectedDate: DayValue
  let today: DayValue
  var exitHandler: (() -> Void)?
  private(set) var currentEvents: [EventOccurrence] = []
  private(set) var detailState = "loading"
  private(set) var documentBottomPadding: CGFloat = 0
  private var pendingAccessibilityElements: [Any]?
  private var pendingFocusedEvent: (generation: Int, identity: String)?
  private var lastFinalDetailDate: DayValue?

  init(anchor: CGRect, display: CGRect, icalBuddy: String, fixture: String?, selected: DayValue?, now: Date? = nil, opener: CalendarOpening = WorkspaceCalendarOpener(), accessibilityNotifier: AccessibilityNotificationPosting = WorkspaceAccessibilityNotifier()) throws {
    today = CalendarMath.value(now ?? Date())
    selectedDate = selected ?? today
    viewYear = selectedDate.year
    viewMonth = selectedDate.month
    provider = try EventProvider(icalBuddy: icalBuddy, fixturePath: fixture)
    hostAnchor = anchor
    displayFrame = display
    injectedNow = now
    self.opener = opener
    self.accessibilityNotifier = accessibilityNotifier
    let origin = CalendarPanelController.panelOrigin(anchor: anchor, display: display)
    panel = CalendarWindow(contentRect: CGRect(origin: origin, size: Self.panelSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    content = NSView(frame: CGRect(origin: .zero, size: Self.panelSize))

    var buttons: [DateButton] = []
    var rows: [[NSView]] = []
    for rowIndex in 0..<6 {
      var row: [NSView] = []
      for columnIndex in 0..<7 {
        let button = DateButton(title: "")
        button.setAccessibilityIdentifier("calendar.date.r\(rowIndex + 1).c\(columnIndex + 1)")
        buttons.append(button)
        row.append(button)
      }
      rows.append(row)
    }
    dateButtons = buttons
    grid = NSGridView(views: rows)

    let weekdayNames = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]
    weekdayLabels = weekdayNames.map { value in
      let label = NSTextField(labelWithString: value)
      label.alignment = .center
      label.textColor = Palette.muted
      label.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
      label.setAccessibilityElement(false)
      return label
    }
    weekdayGrid = NSGridView(views: [weekdayLabels])
    super.init()

    configureWindow()
    configureLayout()
    for button in dateButtons {
      button.handler = { [weak self, weak button] in
        guard let self, let button else { return }
        self.select(button.representedDate)
      }
    }
    renderMonth()
    refreshDetail()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  static func panelOrigin(anchor: CGRect, display: CGRect, height: CGFloat = panelSize.height) -> CGPoint {
    let gap: CGFloat = 4
    let proposedX = anchor.midX - panelSize.width / 2
    let x = min(max(proposedX, display.minX + 8), display.maxX - panelSize.width - 8)
    let proposedY = anchor.minY - gap - height
    let y = min(max(proposedY, display.minY + 8), display.maxY - height - 8)
    return CGPoint(x: x, y: y)
  }

  static func backingAlignedPoint(_ point: CGPoint, scale: CGFloat) -> CGPoint {
    let safeScale = max(1, scale)
    return CGPoint(x: (point.x * safeScale).rounded() / safeScale,
                   y: (point.y * safeScale).rounded() / safeScale)
  }

  static func pointerTestGeometry(point: CGPoint, display: CGRect) -> (host: CGRect, panel: CGRect)? {
    let host = CGRect(x: point.x - 58, y: point.y - 16, width: 116, height: 32)
    let panel = CGRect(origin: panelOrigin(anchor: host, display: display), size: panelSize)
    let safeDisplay = display.insetBy(dx: 8, dy: 8)
    guard host.contains(point),
          panel.minX >= safeDisplay.minX, panel.maxX <= safeDisplay.maxX,
          panel.minY >= safeDisplay.minY, panel.maxY <= safeDisplay.maxY,
          abs((panel.maxY + 4) - host.minY) < 0.01,
          point.x >= panel.minX, point.x <= panel.maxX,
          !panel.intersects(host) else { return nil }
    return (host, panel)
  }

  private func configureWindow() {
    panel.contentView = content
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.hasShadow = false
    panel.level = .popUpMenu
    panel.collectionBehavior = [.transient, .moveToActiveSpace, .fullScreenAuxiliary]
    panel.isReleasedWhenClosed = false
    panel.delegate = self
    panel.hidesOnDeactivate = false
    panel.becomesKeyOnlyIfNeeded = true
    panel.autorecalculatesKeyViewLoop = false
    panel.title = "Calendar"
    panel.setAccessibilityTitle("Calendar")
    content.setAccessibilityElement(true)
    content.setAccessibilityRole(.group)
    content.setAccessibilityLabel("Calendar events")
    content.wantsLayer = true
    content.layer?.backgroundColor = Palette.surface.cgColor
    content.layer?.cornerRadius = 12
    content.layer?.borderWidth = 1
    content.layer?.borderColor = Palette.border.cgColor
    content.layer?.masksToBounds = true
  }

  private func label(_ value: NSTextField, color: NSColor, size: CGFloat, weight: NSFont.Weight, alignment: NSTextAlignment = .left) {
    value.textColor = color
    value.font = NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    value.alignment = alignment
    value.lineBreakMode = .byTruncatingTail
    content.addSubview(value)
  }

  private func navButton(_ title: String, identifier: String, action: @escaping () -> Void) {
    let button = FlatButton(title: title)
    button.setAccessibilityIdentifier(identifier)
    let accessibilityLabels = [
      "calendar.nav.previous-year": "Previous year", "calendar.nav.previous-month": "Previous month",
      "calendar.nav.next-month": "Next month", "calendar.nav.next-year": "Next year",
    ]
    button.setAccessibilityLabel(accessibilityLabels[identifier] ?? title)
    button.setAccessibilityHelp("Change the displayed calendar month")
    button.handler = action
    navButtons.append(button)
    content.addSubview(button)
  }

  private func configureLayout() {
    navButton("«", identifier: "calendar.nav.previous-year") { [weak self] in self?.changeYear(-1) }
    navButton("‹", identifier: "calendar.nav.previous-month") { [weak self] in self?.changeMonth(-1) }
    monthButton.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
    monthButton.contentTintColor = Palette.primary
    monthButton.alignment = .center
    monthButton.setAccessibilityIdentifier("calendar.nav.today")
    monthButton.handler = { [weak self] in self?.returnToToday() }
    content.addSubview(monthButton)
    navButton("›", identifier: "calendar.nav.next-month") { [weak self] in self?.changeMonth(1) }
    navButton("»", identifier: "calendar.nav.next-year") { [weak self] in self?.changeYear(1) }

    weekdayGrid.rowSpacing = 0
    weekdayGrid.columnSpacing = 0
    for index in 0..<weekdayGrid.numberOfColumns { weekdayGrid.column(at: index).width = 36 }
    weekdayGrid.row(at: 0).height = 24
    for label in weekdayLabels {
      if let cell = weekdayGrid.cell(for: label) { cell.xPlacement = .fill; cell.yPlacement = .fill }
    }
    content.addSubview(weekdayGrid)

    grid.rowSpacing = 0
    grid.columnSpacing = 0
    for index in 0..<grid.numberOfColumns { grid.column(at: index).width = 36 }
    for index in 0..<grid.numberOfRows { grid.row(at: index).height = 32 }
    for button in dateButtons {
      if let cell = grid.cell(for: button) { cell.xPlacement = .fill; cell.yPlacement = .fill }
    }
    grid.setAccessibilityElement(true)
    grid.setAccessibilityRole(.radioGroup)
    grid.setAccessibilityIdentifier("calendar.dates")
    content.addSubview(grid)

    label(selectedTitle, color: Palette.muted, size: 10, weight: .bold)
    selectedTitle.setAccessibilityElement(true)
    if #available(macOS 26.0, *) { selectedTitle.setAccessibilityRole(.headingRole) }
    else { selectedTitle.setAccessibilityRole(.staticText) }
    selectedTitle.setAccessibilityIdentifier("calendar.selected.heading")
    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder
    scrollView.hasHorizontalScroller = false
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.verticalScrollElasticity = .none
    scrollView.horizontalScrollElasticity = .none
    scrollView.setAccessibilityIdentifier("calendar.events.scroll")
    scrollView.setAccessibilityElement(true)
    scrollView.setAccessibilityRole(.scrollArea)
    eventDocument.setAccessibilityIdentifier("calendar.events.document")
    eventDocument.setAccessibilityElement(true)
    eventDocument.setAccessibilityRole(.group)
    scrollView.documentView = eventDocument
    content.addSubview(scrollView)
    layoutForCurrentHeight()
    rebuildDetail(state: "loading", events: [])
  }

  private func layoutForCurrentHeight() {
    let height = content.bounds.height
    navButtons[0].frame = CGRect(x: 12, y: height - 48, width: 34, height: 40)
    navButtons[1].frame = CGRect(x: 46, y: height - 48, width: 32, height: 40)
    monthButton.frame = CGRect(x: 78, y: height - 48, width: 144, height: 40)
    navButtons[2].frame = CGRect(x: 222, y: height - 48, width: 32, height: 40)
    navButtons[3].frame = CGRect(x: 254, y: height - 48, width: 34, height: 40)
    weekdayGrid.frame = CGRect(x: 24, y: height - 72, width: 252, height: 24)
    grid.frame = CGRect(x: 24, y: height - 264, width: 252, height: 192)
    selectedTitle.frame = CGRect(x: 16, y: height - 290, width: 268, height: 22)
    scrollView.frame = CGRect(x: 12, y: 12, width: 276, height: max(54, height - Self.fixedTopHeight))
    layoutEventDocument()
  }

  private func rebuildKeyViewLoop() {
    let ordered: [NSView] = [navButtons[0], navButtons[1], monthButton, navButtons[2], navButtons[3]] + dateButtons + eventRows
    for index in ordered.indices {
      ordered[index].nextKeyView = ordered[(index + 1) % ordered.count]
    }
    panel.initialFirstResponder = dateButtons.first { $0.representedDate == selectedDate } ?? dateButtons.first
  }

  private func desiredPanelHeight(documentHeight: CGFloat) -> CGFloat {
    let top = hostAnchor.minY - 4
    let displayLimit = max(Self.panelSize.height, top - (displayFrame.minY + 8))
    let maximum = min(Self.maximumPreferredHeight, displayLimit)
    return min(max(Self.panelSize.height, Self.fixedTopHeight + documentHeight), maximum)
  }

  func expectedPanelFrame() -> CGRect {
    let desired = desiredPanelHeight(documentHeight: eventDocument.frame.height)
    let origin = Self.panelOrigin(anchor: hostAnchor, display: displayFrame, height: desired)
    return CGRect(origin: origin, size: CGSize(width: Self.panelSize.width, height: desired))
  }

  private func resizeForDocument() {
    let expected = expectedPanelFrame()
    let desired = expected.height
    panel.setFrame(expected, display: panel.isVisible, animate: false)
    content.frame = CGRect(origin: .zero, size: CGSize(width: Self.panelSize.width, height: desired))
    layoutForCurrentHeight()
  }

  private func detailLabel(_ text: String, identifier: String, y: CGFloat, height: CGFloat = 22) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.frame = CGRect(x: 8, y: y, width: max(0, eventDocument.bounds.width - 16), height: height)
    label.textColor = Palette.muted
    label.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
    label.setAccessibilityIdentifier(identifier)
    label.setAccessibilityLabel(text)
    eventDocument.addSubview(label)
    detailLabels.append(label)
    return label
  }

  private static func compactDuration(_ interval: TimeInterval) -> String {
    let minutes = max(1, Int((interval / 60).rounded()))
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    let remaining = minutes % 60
    if hours < 24 { return remaining == 0 ? "\(hours)h" : "\(hours)h \(remaining)m" }
    let days = hours / 24
    let leftover = hours % 24
    return leftover == 0 ? "\(days)d" : "\(days)d \(leftover)h"
  }

  private static func spokenDuration(_ interval: TimeInterval) -> String {
    var minutes = max(1, Int((interval / 60).rounded()))
    let days = minutes / 1440
    minutes %= 1440
    let hours = minutes / 60
    minutes %= 60
    var parts: [String] = []
    if days > 0 { parts.append("\(days) \(days == 1 ? "day" : "days")") }
    if hours > 0 { parts.append("\(hours) \(hours == 1 ? "hour" : "hours")") }
    if minutes > 0 { parts.append("\(minutes) \(minutes == 1 ? "minute" : "minutes")") }
    return parts.joined(separator: " ")
  }

  private static func detail(for event: EventOccurrence, selected: DayValue, now: Date) -> String {
    if event.allDay { return "All day · \(EventPhase.value(for: event, now: now).rawValue)" }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = CalendarMath.value(event.start) == selected ? "h:mm a" : "EEE h:mm a"
    return "\(formatter.string(from: event.start)) · \(compactDuration(event.duration)) · \(EventPhase.value(for: event, now: now).rawValue)"
  }

  static func accessibilityDetail(for event: EventOccurrence, selected: DayValue, now: Date) -> String {
    let phase: String
    switch EventPhase.value(for: event, now: now) {
    case .ended: phase = "Ended."
    case .ongoing: phase = "In progress."
    case .upcoming: phase = "Upcoming."
    }
    if event.allDay { return "All-day event. Duration \(spokenDuration(event.duration)). \(phase)" }
    let startDay = CalendarMath.value(event.start)
    let endDay = CalendarMath.value(event.end)
    let includeDates = startDay != selected || endDay != selected
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = includeDates ? "EEEE, MMMM d 'at' h:mm a" : "'at' h:mm a"
    return "Starts \(formatter.string(from: event.start)). Ends \(formatter.string(from: event.end)). Duration \(spokenDuration(event.duration)). \(phase)"
  }

  private func addSection(_ title: String, identifier: String, y: inout CGFloat) {
    let heading = detailLabel(title, identifier: identifier, y: y, height: 18)
    heading.setAccessibilityElement(true)
    if #available(macOS 26.0, *) { heading.setAccessibilityRole(.headingRole) }
    else { heading.setAccessibilityRole(.staticText) }
    heading.setAccessibilityLabel("\(title.capitalized) events")
    y += 18
  }

  private func addEvent(_ event: EventOccurrence, y: inout CGFloat) {
    let row = EventRowButton()
    let referenceNow = injectedNow ?? Date()
    let detail = Self.detail(for: event, selected: selectedDate, now: referenceNow)
    let accessibilityDetail = Self.accessibilityDetail(for: event, selected: selectedDate, now: referenceNow)
    row.configure(event, detail: detail, accessibilityDetail: accessibilityDetail)
    row.frame = CGRect(x: 0, y: y, width: max(0, eventDocument.bounds.width), height: 44)
    row.handler = { [weak self, weak row] in
      guard let self, let event = row?.occurrence else { return }
      EventActionRouter.perform(event, opener: self.opener)
    }
    eventDocument.addSubview(row)
    eventRows.append(row)
    y += 44
  }

  private func layoutEventDocument() {
    let width = max(252, scrollView.contentSize.width)
    eventDocument.frame.size.width = width
    for row in eventRows { row.frame.size.width = width; row.needsLayout = true }
    for label in detailLabels { label.frame.size.width = max(0, width - 16) }
  }

  private func publishAccessibilityElements(_ elements: [Any]) {
    for element in elements { accessibilityNotifier.created(element) }
    accessibilityNotifier.layoutChanged(eventDocument, elements: elements)
  }

  func flushPendingAccessibilityNotifications() {
    guard let elements = pendingAccessibilityElements else { return }
    pendingAccessibilityElements = nil
    publishAccessibilityElements(elements)
  }

  static func shouldPreserveScroll(requested: DayValue, lastFinal: DayValue?, focusedIdentity: String?) -> Bool {
    lastFinal == requested && focusedIdentity != nil
  }

  static func restorationIdentity(pendingGeneration: Int?, pendingIdentity: String?, acceptedGeneration: Int) -> String? {
    pendingGeneration == acceptedGeneration ? pendingIdentity : nil
  }

  static func preferredFocusIdentity(previous: String?, events: [EventOccurrence]) -> String? {
    guard let previous else { return nil }
    if events.contains(where: { $0.identity == previous }) { return previous }
    return events.first?.identity
  }

  static func alignedBottomPadding(documentHeight: CGFloat, viewportHeight: CGFloat, boundaries: [CGFloat]) -> CGFloat {
    guard documentHeight > viewportHeight else { return 0 }
    let rawMaximum = documentHeight - viewportHeight
    guard let boundary = boundaries.sorted().first(where: { $0 >= rawMaximum }) else { return 0 }
    return boundary - rawMaximum
  }

  private func rebuildDetail(state: String, events: [EventOccurrence], restoringIdentity: String? = nil) {
    let focusedEventRow = panel.firstResponder as? EventRowButton
    let focusedIdentity = restoringIdentity ?? focusedEventRow?.occurrence?.identity ?? eventRows.first(where: { $0.isAccessibilityFocused() })?.occurrence?.identity
    if state == "loading" { pendingAccessibilityElements = nil }
    detailState = state
    currentEvents = events
    for view in eventDocument.subviews { view.removeFromSuperview() }
    eventRows.removeAll()
    detailLabels.removeAll()
    eventDocument.frame = CGRect(x: 0, y: 0, width: max(252, scrollView.contentSize.width), height: 54)
    var y: CGFloat = 0
    if state == "events" {
      let allDay = events.filter(\.allDay)
      let timed = events.filter { !$0.allDay }
      if !allDay.isEmpty {
        addSection("ALL DAY", identifier: "calendar.section.all-day", y: &y)
        for event in allDay { addEvent(event, y: &y) }
      }
      if !timed.isEmpty {
        addSection("TIMED", identifier: "calendar.section.timed", y: &y)
        for event in timed { addEvent(event, y: &y) }
      }
    } else {
      let text: String
      switch state {
      case "loading": text = "Loading events…"
      case "empty": text = "No events"
      case "permission": text = "Calendar permission required"
      case "malformed": text = "Calendar data malformed"
      default: text = "Calendar unavailable"
      }
      _ = detailLabel(text, identifier: "calendar.state.\(state)", y: 14, height: 24)
      y = 54
    }
    let unpaddedDocumentHeight = max(54, y)
    var documentHeight = unpaddedDocumentHeight
    documentBottomPadding = 0
    let availableViewport = desiredPanelHeight(documentHeight: documentHeight) - Self.fixedTopHeight
    if documentHeight > availableViewport {
      let sectionStarts = detailLabels.filter { $0.accessibilityIdentifier().hasPrefix("calendar.section.") }.map(\.frame.minY)
      let alignmentBoundaries = eventRows.map(\.frame.minY) + sectionStarts
      documentBottomPadding = Self.alignedBottomPadding(documentHeight: documentHeight, viewportHeight: availableViewport, boundaries: alignmentBoundaries)
      documentHeight += documentBottomPadding
    }
    eventDocument.frame.size.height = documentHeight
    resizeForDocument()
    eventDocument.needsLayout = true
    content.layoutSubtreeIfNeeded()
    rebuildKeyViewLoop()
    let preferredIdentity = Self.preferredFocusIdentity(previous: focusedIdentity, events: events)
    let selectedButton = dateButtons.first { $0.representedDate == selectedDate } ?? dateButtons[0]
    let focusTarget: NSView = preferredIdentity.flatMap { identity in eventRows.first { $0.occurrence?.identity == identity } } ?? selectedButton
    if panel.isKeyWindow && focusedIdentity != nil { panel.makeFirstResponder(focusTarget) }
    if state != "loading" {
      var liveElements: [Any] = detailLabels + eventRows
      if let focusedIdentity, let focusedRow = eventRows.first(where: { $0.occurrence?.identity == focusedIdentity }) {
        liveElements.removeAll { ($0 as AnyObject) === focusedRow }
        liveElements.insert(focusedRow, at: 0)
      }
      if panel.isVisible { publishAccessibilityElements(liveElements) }
      else { pendingAccessibilityElements = liveElements }
    }
  }

  func returnToToday() {
    guard selectedDate != today || viewYear != today.year || viewMonth != today.month else { return }
    select(today)
  }

  func changeMonth(_ delta: Int) {
    let shifted = CalendarMath.shifted(year: viewYear, month: viewMonth, by: delta)
    let day = min(selectedDate.day, CalendarMath.daysInMonth(year: shifted.0, month: shifted.1))
    select(DayValue(year: shifted.0, month: shifted.1, day: day))
  }

  func changeYear(_ delta: Int) {
    let year = min(max(viewYear + delta, CalendarMath.supportedYears.lowerBound), CalendarMath.supportedYears.upperBound)
    let day = min(selectedDate.day, CalendarMath.daysInMonth(year: year, month: viewMonth))
    select(DayValue(year: year, month: viewMonth, day: day))
  }

  func select(_ date: DayValue) {
    let previousDate = selectedDate
    let previous = dateButtons.first { $0.representedDate == selectedDate }
    let shouldFocusSelectedDate = panel.firstResponder is DateButton || panel.firstResponder === monthButton
    selectedDate = date
    if CalendarMath.supportedYears.contains(date.year) && (date.year != viewYear || date.month != viewMonth) {
      viewYear = date.year
      viewMonth = date.month
    }
    renderMonth()
    let current = dateButtons.first { $0.representedDate == selectedDate }
    if panel.isKeyWindow && shouldFocusSelectedDate, let current { panel.makeFirstResponder(current) }
    if previousDate != date {
      if previous === current {
        if let current { accessibilityNotifier.valueChanged(current) }
      } else {
        if let previous { accessibilityNotifier.valueChanged(previous) }
        if let current { accessibilityNotifier.valueChanged(current) }
      }
    }
    refreshDetail()
  }

  func renderMonth() {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "MMMM yyyy"
    let month = formatter.string(from: CalendarMath.date(DayValue(year: viewYear, month: viewMonth, day: 1))).uppercased()
    grid.setAccessibilityLabel("Dates for \(month.capitalized)")
    let awayFromToday = selectedDate != today || viewYear != today.year || viewMonth != today.month
    monthButton.title = month + (awayFromToday ? " ↩" : "")
    monthButton.toolTip = awayFromToday ? "Return to Today" : "Current month"
    monthButton.setAccessibilityLabel(awayFromToday ? "\(month.capitalized), return to today" : month.capitalized)
    monthButton.setAccessibilityHelp(awayFromToday ? "Return to Today" : "Current calendar month")
    let cells = CalendarMath.cells(year: viewYear, month: viewMonth)
    for (index, cell) in cells.enumerated() { dateButtons[index].configure(cell: cell, today: today, selected: selectedDate) }
    rebuildKeyViewLoop()
    content.layoutSubtreeIfNeeded()
  }

  func refreshDetail() {
    let token = gate.begin()
    let requested = selectedDate
    let observedFocusedIdentity = (panel.firstResponder as? EventRowButton)?.occurrence?.identity ?? eventRows.first(where: { $0.isAccessibilityFocused() })?.occurrence?.identity
    let focusedIdentity = Self.shouldPreserveScroll(requested: requested, lastFinal: lastFinalDetailDate, focusedIdentity: observedFocusedIdentity) ? observedFocusedIdentity : nil
    pendingFocusedEvent = focusedIdentity.map { (generation: token, identity: $0) }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "EEE, MMM d"
    let shortSelectedDate = formatter.string(from: CalendarMath.date(requested))
    formatter.dateFormat = "EEEE, MMMM d, yyyy"
    let fullSelectedDate = formatter.string(from: CalendarMath.date(requested))
    formatter.dateFormat = "EEE, MMM d"
    eventDocument.setAccessibilityLabel("Events for \(fullSelectedDate)")
    selectedTitle.stringValue = "SELECTED · " + shortSelectedDate.uppercased()
    selectedTitle.setAccessibilityLabel("Selected day, \(fullSelectedDate)")
    if focusedIdentity == nil {
      scrollView.contentView.scroll(to: .zero)
      scrollView.reflectScrolledClipView(scrollView.contentView)
      rebuildDetail(state: "loading", events: [])
    } else { detailState = "loading" }
    provider.query(requested) { [weak self] result in
      guard let self, self.gate.accepts(token), self.selectedDate == requested else { return }
      let restoringIdentity = Self.restorationIdentity(pendingGeneration: self.pendingFocusedEvent?.generation, pendingIdentity: self.pendingFocusedEvent?.identity, acceptedGeneration: token)
      self.pendingFocusedEvent = nil
      self.lastFinalDetailDate = requested
      switch result {
      case .events(let values):
        self.selectedTitle.stringValue = "SELECTED · \(shortSelectedDate.uppercased()) · \(values.count) \(values.count == 1 ? "EVENT" : "EVENTS")"
        self.selectedTitle.setAccessibilityLabel("Selected day, \(fullSelectedDate), \(values.count) \(values.count == 1 ? "event" : "events")")
        self.rebuildDetail(state: "events", events: values, restoringIdentity: restoringIdentity)
      case .empty:
        self.selectedTitle.stringValue = "SELECTED · \(shortSelectedDate.uppercased()) · 0 EVENTS"
        self.selectedTitle.setAccessibilityLabel("Selected day, \(fullSelectedDate), 0 events")
        self.rebuildDetail(state: "empty", events: [], restoringIdentity: restoringIdentity)
      case .permission: self.rebuildDetail(state: "permission", events: [], restoringIdentity: restoringIdentity)
      case .malformed: self.rebuildDetail(state: "malformed", events: [], restoringIdentity: restoringIdentity)
      case .error: self.rebuildDetail(state: "error", events: [], restoringIdentity: restoringIdentity)
      }
    }
  }

  func hasFocusedAccessibilityDescendant() -> Bool {
    if panel.isAccessibilityFocused() { return true }
    let knownViews: [NSView] = [content, monthButton, selectedTitle, weekdayGrid, grid, scrollView, eventDocument] + weekdayLabels + navButtons + dateButtons + detailLabels + eventRows
    return knownViews.contains { $0.isAccessibilityFocused() }
  }

  func scrollToBottom() {
    let maximum = max(0, eventDocument.frame.height - scrollView.contentView.bounds.height)
    scrollView.contentView.scroll(to: CGPoint(x: 0, y: maximum))
    scrollView.reflectScrolledClipView(scrollView.contentView)
  }

  func show() {
    panel.orderFrontRegardless()
    flushPendingAccessibilityNotifications()
  }

  func windowWillClose(_ notification: Notification) { exitHandler?() }

  func geometry() -> [String: Any] {
    content.layoutSubtreeIfNeeded()
    let cells = dateButtons.map { button -> [String: Any] in
      let rect = button.convert(button.bounds, to: content)
      let unignored = NSAccessibility.unignoredAncestor(of: button) as AnyObject
      return ["identifier": button.accessibilityIdentifier(), "accessibility_label": button.accessibilityLabel() ?? "", "accessibility_selected": button.selectedForAccessibility, "unignored": unignored === button, "accessibility_value": (button.accessibilityValue() as? NSNumber)?.boolValue ?? false, "role": button.accessibilityRole()?.rawValue ?? "", "date": button.representedDate.key, "x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height,
              "accepts_first_responder": button.acceptsFirstResponder, "can_become_key_view": button.canBecomeKeyView, "needs_panel_to_become_key": button.needsPanelToBecomeKey,
              "focus_mask_x": button.focusRingMaskBounds.minX, "focus_mask_y": button.focusRingMaskBounds.minY,
              "focus_mask_width": button.focusRingMaskBounds.width, "focus_mask_height": button.focusRingMaskBounds.height]
    }
    let headers = weekdayLabels.map { label -> [String: Any] in
      let rect = label.convert(label.bounds, to: content)
      return ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height, "accessibility_element": label.isAccessibilityElement()]
    }
    let navigation = navButtons.map { button -> [String: Any] in
      let rect = button.convert(button.bounds, to: content)
      return ["identifier": button.accessibilityIdentifier(), "accessibility_label": button.accessibilityLabel() ?? "", "x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]
    }
    let rows = eventRows.map { row -> [String: Any] in
      let titlePoint = eventDocument.convert(CGPoint(x: row.titleLabel.bounds.midX, y: row.titleLabel.bounds.midY), from: row.titleLabel)
      let detailPoint = eventDocument.convert(CGPoint(x: row.detailLabel.bounds.midX, y: row.detailLabel.bounds.midY), from: row.detailLabel)
      let meetingPoint = eventDocument.convert(CGPoint(x: row.meetingLabel.bounds.midX, y: row.meetingLabel.bounds.midY), from: row.meetingLabel)
      let rowMidpointInSuperview = row.convert(CGPoint(x: row.bounds.midX, y: row.bounds.midY), to: eventDocument)
      let unignored = NSAccessibility.unignoredAncestor(of: row) as AnyObject
      let titleAncestor = NSAccessibility.unignoredAncestor(of: row.titleLabel) as AnyObject
      let detailAncestor = NSAccessibility.unignoredAncestor(of: row.detailLabel) as AnyObject
      let meetingAncestor = NSAccessibility.unignoredAncestor(of: row.meetingLabel) as AnyObject
      return ["identifier": row.accessibilityIdentifier(), "label": row.accessibilityLabel() ?? "", "role": row.accessibilityRole()?.rawValue ?? "",
       "unignored": unignored === row,
       "nested_title_accessibility_element": row.titleLabel.isAccessibilityElement(),
       "nested_detail_accessibility_element": row.detailLabel.isAccessibilityElement(),
       "nested_meeting_accessibility_element": row.meetingLabel.isAccessibilityElement(),
       "nested_title_unignored_row": titleAncestor === row, "nested_detail_unignored_row": detailAncestor === row,
       "nested_meeting_unignored_row": meetingAncestor === row,
       "nested_title_hits_row": eventDocument.hitTest(titlePoint) === row, "nested_detail_hits_row": eventDocument.hitTest(detailPoint) === row,
       "nested_meeting_hits_row": eventDocument.hitTest(meetingPoint) === row,
       "superview_midpoint_hits_row": row.hitTest(rowMidpointInSuperview) === row,
       "nonzero_document_origin": row.frame.minY > 0,
       "title": row.titleLabel.stringValue,
       "title_frame_y": row.titleLabel.frame.minY, "title_frame_max_y": row.titleLabel.frame.maxY,
       "title_frame_width": row.titleLabel.frame.width,
       "meeting_affordance": row.meetingLabel.isHidden ? "" : row.meetingLabel.stringValue,
       "meeting_tooltip": row.meetingLabel.toolTip ?? "", "meeting_frame_width": row.meetingLabel.frame.width,
       "detail_frame_y": row.detailLabel.frame.minY, "detail_frame_max_y": row.detailLabel.frame.maxY,
       "detail": row.detailLabel.stringValue, "detail_intrinsic_width": row.detailLabel.intrinsicContentSize.width, "x": row.frame.minX, "y": row.frame.minY, "width": row.frame.width, "height": row.frame.height,
       "meeting": row.occurrence?.meetingURL != nil]
    }
    let viewport = scrollView.contentView.bounds
    let topOffset = viewport.minY
    let bottomOffset = max(0, eventDocument.frame.height - viewport.height)
    let firstFrame = eventRows.first?.frame
    let scrollAlignmentBoundaries = (eventRows.map(\.frame.minY) + detailLabels.filter { $0.accessibilityIdentifier().hasPrefix("calendar.section.") }.map(\.frame.minY)).sorted()
    let lastFrame = eventRows.last?.frame
    let monthRect = monthButton.convert(monthButton.bounds, to: content)
    let keyViews: [NSView] = [navButtons[0], navButtons[1], monthButton, navButtons[2], navButtons[3]] + dateButtons + eventRows
    var actualKeyOrder: [String] = []
    var visitedKeyViews = Set<ObjectIdentifier>()
    var keyCursor: NSView? = navButtons[0]
    while let current = keyCursor, !visitedKeyViews.contains(ObjectIdentifier(current)), actualKeyOrder.count <= keyViews.count {
      visitedKeyViews.insert(ObjectIdentifier(current))
      actualKeyOrder.append(current.accessibilityIdentifier())
      keyCursor = current.nextKeyView
    }
    let keyLoopClosed = keyCursor === navButtons[0]
    let gridUnignored = (NSAccessibility.unignoredAncestor(of: grid) as AnyObject) === grid
    return [
      "panel": ["x": panel.frame.minX, "y": panel.frame.minY, "width": panel.frame.width, "height": panel.frame.height],
      "display": ["x": displayFrame.minX, "y": displayFrame.minY, "width": displayFrame.width, "height": displayFrame.height],
      "host": ["x": hostAnchor.minX, "y": hostAnchor.minY, "width": hostAnchor.width, "height": hostAnchor.height],
      "cells": cells, "headers": headers, "navigation": navigation,
      "month_control": ["identifier": monthButton.accessibilityIdentifier(), "label": monthButton.accessibilityLabel() ?? "", "help": monthButton.accessibilityHelp() ?? "", "title": monthButton.title,
                        "role": monthButton.accessibilityRole()?.rawValue ?? "", "unignored": (NSAccessibility.unignoredAncestor(of: monthButton) as AnyObject) === monthButton,
                        "accepts_first_responder": monthButton.acceptsFirstResponder, "can_become_key_view": monthButton.canBecomeKeyView,
                        "needs_panel_to_become_key": monthButton.needsPanelToBecomeKey,
                        "x": monthRect.minX, "y": monthRect.minY, "width": monthRect.width, "height": monthRect.height],
      "detail_state": detailState, "event_count": currentEvents.count, "event_rows": rows,
      "accessibility": ["window_title": panel.title, "panel_title": panel.accessibilityTitle() ?? "", "grid_identifier": grid.accessibilityIdentifier(),
                          "grid_label": grid.accessibilityLabel() ?? "", "grid_role": grid.accessibilityRole()?.rawValue ?? "", "grid_unignored": gridUnignored,
                          "event_group_label": eventDocument.accessibilityLabel() ?? "", "event_group_role": eventDocument.accessibilityRole()?.rawValue ?? "",
                          "event_group_unignored": (NSAccessibility.unignoredAncestor(of: eventDocument) as AnyObject) === eventDocument,
                          "event_group_is_document_view": scrollView.documentView === eventDocument,
                          "section_roles": detailLabels.filter { $0.accessibilityIdentifier().hasPrefix("calendar.section.") }.map { $0.accessibilityRole()?.rawValue ?? "" },
                          "selected_identifier": selectedTitle.accessibilityIdentifier(),
                          "selected_label": selectedTitle.accessibilityLabel() ?? "", "selected_visual": selectedTitle.stringValue, "selected_role": selectedTitle.accessibilityRole()?.rawValue ?? "",
                          "scroll_identifier": scrollView.accessibilityIdentifier(), "document_identifier": eventDocument.accessibilityIdentifier(),
                          "first_role": eventRows.first?.accessibilityRole()?.rawValue ?? "", "last_role": eventRows.last?.accessibilityRole()?.rawValue ?? "",
                          "key_order": actualKeyOrder, "expected_key_order": keyViews.map { $0.accessibilityIdentifier() },
                          "key_order_unique": Set(actualKeyOrder).count == actualKeyOrder.count,
                          "key_loop_closed": keyLoopClosed, "autorecalculates_key_view_loop": panel.autorecalculatesKeyViewLoop,
                          "initial_responder": panel.initialFirstResponder?.accessibilityIdentifier() ?? ""],
      "scroll": ["viewport_height": viewport.height, "viewport_min_y": viewport.minY, "viewport_max_y": viewport.maxY,
                 "document_height": eventDocument.frame.height, "bottom_padding": documentBottomPadding,
                 "alignment_boundaries": scrollAlignmentBoundaries,
                 "offset_y": topOffset, "maximum_offset_y": bottomOffset,
                 "required": eventDocument.frame.height > viewport.height,
                 "first_row_min_y": firstFrame?.minY ?? 0, "first_row_max_y": firstFrame?.maxY ?? 0,
                 "last_row_min_y": lastFrame?.minY ?? 0, "last_row_max_y": lastFrame?.maxY ?? 0,
                 "first_fully_visible": firstFrame.map { viewport.minY <= $0.minY && viewport.maxY >= $0.maxY } ?? true,
                 "last_fully_visible": lastFrame.map { viewport.minY <= $0.minY && viewport.maxY >= $0.maxY } ?? true],
    ]
  }

  func renderPNG(path: String) throws {
    content.layoutSubtreeIfNeeded()
    guard let representation = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { throw NSError(domain: "CalendarPanel", code: 1) }
    content.cacheDisplay(in: content.bounds, to: representation)
    guard let data = representation.representation(using: .png, properties: [:]) else { throw NSError(domain: "CalendarPanel", code: 2) }
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
  }
}


private struct DisplayAnchorMapping {
  let id: CGDirectDisplayID
  let cgBounds: CGRect
  let appKitFrame: CGRect
}

private enum ProductionAnchorResolution {
  case success(anchor: CGRect, display: CGRect, id: CGDirectDisplayID)
  case invalid
  case pointerMismatch
}

private enum ProductionAnchorResolver {
  static let expectedSize = CGSize(width: 116, height: 32)
  private static let coordinateLimit: CGFloat = 10_000_000

  static func validInput(_ rect: CGRect) -> Bool {
    let values = [rect.origin.x, rect.origin.y, rect.width, rect.height]
    return values.allSatisfy { $0.isFinite && abs($0) <= coordinateLimit } && rect.size == expectedSize
  }

  static func convert(_ rect: CGRect, mappings: [DisplayAnchorMapping]) -> (anchor: CGRect, display: CGRect, id: CGDirectDisplayID)? {
    guard validInput(rect) else { return nil }
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let matches = mappings.filter { mapping in
      let bounds = mapping.cgBounds
      return [bounds.minX, bounds.minY, bounds.width, bounds.height].allSatisfy { $0.isFinite && abs($0) <= coordinateLimit } &&
        bounds.contains(center) && rect.minX >= bounds.minX && rect.maxX <= bounds.maxX &&
        rect.minY >= bounds.minY && rect.maxY <= bounds.maxY
    }
    guard matches.count == 1, let mapping = matches.first else { return nil }
    let localX = rect.minX - mapping.cgBounds.minX
    let localTop = rect.minY - mapping.cgBounds.minY
    let anchor = CGRect(x: mapping.appKitFrame.minX + localX,
                        y: mapping.appKitFrame.maxY - localTop - rect.height,
                        width: rect.width, height: rect.height)
    guard [anchor.minX, anchor.minY, anchor.width, anchor.height].allSatisfy({ $0.isFinite && abs($0) <= coordinateLimit }),
          mapping.appKitFrame.contains(CGPoint(x: anchor.midX, y: anchor.midY)),
          anchor.minX >= mapping.appKitFrame.minX, anchor.maxX <= mapping.appKitFrame.maxX,
          anchor.minY >= mapping.appKitFrame.minY, anchor.maxY <= mapping.appKitFrame.maxY else { return nil }
    return (anchor, mapping.appKitFrame, mapping.id)
  }

  static let maximumCandidates = 16

  static func select(_ candidates: [CGRect], mappings: [DisplayAnchorMapping], pointer: CGPoint) -> ProductionAnchorResolution {
    guard !candidates.isEmpty, candidates.count <= maximumCandidates else { return .invalid }
    guard pointer.x.isFinite, pointer.y.isFinite else { return .pointerMismatch }
    let converted = candidates.compactMap { convert($0, mappings: mappings) }
    guard converted.count == candidates.count else { return .invalid }
    let matches = converted.filter { $0.anchor.contains(pointer) }
    guard matches.count == 1 else { return .pointerMismatch }
    let match = matches[0]
    return .success(anchor: match.anchor, display: match.display, id: match.id)
  }

  static func resolve(_ candidates: [CGRect], pointer: CGPoint) -> ProductionAnchorResolution {
    guard !candidates.isEmpty, candidates.count <= maximumCandidates else { return .invalid }
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0, count <= 64 else { return .invalid }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return .invalid }
    ids = Array(ids.prefix(Int(count)))
    guard Set(ids).count == ids.count else { return .invalid }
    var screensByID: [CGDirectDisplayID: NSScreen] = [:]
    for screen in NSScreen.screens {
      guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
      let id = CGDirectDisplayID(number.uint32Value)
      guard screensByID[id] == nil else { return .invalid }
      screensByID[id] = screen
    }
    let mappings = ids.compactMap { id -> DisplayAnchorMapping? in
      guard let screen = screensByID[id] else { return nil }
      return DisplayAnchorMapping(id: id, cgBounds: CGDisplayBounds(id), appKitFrame: screen.frame)
    }
    guard mappings.count == ids.count else { return .invalid }
    return select(candidates, mappings: mappings, pointer: pointer)
  }
}

private struct Arguments {
  var close = false
  var toggle = false
  var selfTest = false
  var holdTest = false
  var contenderTest = false
  var anchorCurrentPointer = false
  var anchorCG: [CGRect] = []
  var stateReport: String?
  var scrollBottom = false
  var render: String?
  var geometry: String?
  var fixture: String?
  var icalBuddy = "/opt/homebrew/bin/icalBuddy"
  var anchor = CGRect(x: 1212, y: 950, width: 116, height: 32)
  var display = CGRect(x: 0, y: 0, width: 1512, height: 982)
  var selected: DayValue?
  var now: Date?
  var usageInvalid = false

  init() {
    var index = 1
    let values = CommandLine.arguments
    var seen: Set<String> = []
    func claim(_ name: String) -> Bool {
      if seen.contains(name) { return false }
      seen.insert(name)
      return true
    }
    func finite(_ values: [Double]) -> Bool {
      values.allSatisfy { $0.isFinite && abs($0) <= 10_000_000 }
    }
    while index < values.count && !usageInvalid {
      let flag = values[index]
      switch flag {
      case "--close":
        guard claim(flag) else { usageInvalid = true; break }
        close = true
      case "--toggle":
        guard claim(flag) else { usageInvalid = true; break }
        toggle = true
      case "--self-test":
        guard claim(flag) else { usageInvalid = true; break }
        selfTest = true
      case "--hold-test":
        guard claim(flag) else { usageInvalid = true; break }
        holdTest = true
      case "--contender-test":
        guard claim(flag) else { usageInvalid = true; break }
        contenderTest = true
      case "--anchor-current-pointer":
        guard claim(flag) else { usageInvalid = true; break }
        anchorCurrentPointer = true
      case "--scroll-bottom":
        guard claim(flag) else { usageInvalid = true; break }
        scrollBottom = true
      case "--state-report", "--render", "--geometry", "--fixture", "--ical-buddy", "--date", "--now":
        guard claim(flag), index + 1 < values.count else { usageInvalid = true; break }
        index += 1
        let value = values[index]
        guard !value.isEmpty else { usageInvalid = true; break }
        switch flag {
        case "--state-report": stateReport = value
        case "--render": render = value
        case "--geometry": geometry = value
        case "--fixture": fixture = value
        case "--ical-buddy": icalBuddy = value
        case "--date":
          let fields = value.split(separator: "-", omittingEmptySubsequences: false)
          guard fields.count == 3, let year = Int(fields[0]), let month = Int(fields[1]), let dayValue = Int(fields[2]) else { usageInvalid = true; break }
          let day = DayValue(year: year, month: month, day: dayValue)
          guard CalendarMath.supportedYears.contains(day.year), CalendarMath.isValid(day) else { usageInvalid = true; break }
          selected = day
        case "--now":
          let formatter = ISO8601DateFormatter()
          formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTimeZone]
          guard let parsed = formatter.date(from: value) else { usageInvalid = true; break }
          now = parsed
        default: break
        }
      case "--anchor-cg", "--anchor", "--display":
        if flag != "--anchor-cg" && !claim(flag) { usageInvalid = true; break }
        guard index + 4 < values.count,
              let x = Double(values[index + 1]), let y = Double(values[index + 2]),
              let width = Double(values[index + 3]), let height = Double(values[index + 4]),
              finite([x, y, width, height]) else { usageInvalid = true; break }
        let rect = CGRect(x: x, y: y, width: width, height: height)
        if flag == "--anchor-cg" {
          guard anchorCG.count < ProductionAnchorResolver.maximumCandidates,
                ProductionAnchorResolver.validInput(rect) else { usageInvalid = true; break }
          anchorCG.append(rect)
        } else if flag == "--anchor" {
          guard width > 0, height > 0 else { usageInvalid = true; break }
          anchor = rect
        } else {
          guard width > 0, height > 0 else { usageInvalid = true; break }
          display = rect
        }
        index += 4
      default:
        usageInvalid = true
      }
      index += 1
    }

    let primaryModes = [close, selfTest, render != nil, anchorCurrentPointer, holdTest, contenderTest].filter { $0 }.count
    if primaryModes > 1 || (toggle && (close || selfTest || render != nil || anchorCurrentPointer)) { usageInvalid = true }
    if anchorCurrentPointer != (stateReport != nil) { usageInvalid = true }
    if !anchorCG.isEmpty && !toggle { usageInvalid = true }
    if close && seen != Set(["--close"]) { usageInvalid = true }
    if selfTest && seen != Set(["--self-test"]) { usageInvalid = true }
    if holdTest {
      let allowed = toggle ? Set(["--toggle", "--hold-test"]) : Set(["--hold-test"])
      if seen != allowed { usageInvalid = true }
    }
    if holdTest || contenderTest {
      let instance = ProcessInfo.processInfo.environment["SKETCHYBAR_CALENDAR_PANEL_INSTANCE"] ?? ""
      let validInstance = !instance.isEmpty && instance.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" || $0 == "_" }
      if !validInstance { usageInvalid = true }
    }
    if contenderTest && seen != Set(["--contender-test", "--ical-buddy"]) { usageInvalid = true }
    if geometry != nil && render == nil || scrollBottom && render == nil { usageInvalid = true }
    let testOnlyArguments = fixture != nil || selected != nil || now != nil || seen.contains("--anchor") || seen.contains("--display")
    if testOnlyArguments && render == nil { usageInvalid = true }
    if render != nil && (fixture == nil || !anchorCG.isEmpty) { usageInvalid = true }
    if !close && !toggle && !selfTest && !holdTest && !contenderTest && render == nil && !anchorCurrentPointer { usageInvalid = true }
  }
}

private let runtimeDirectory: String = {
  let path = FileManager.default.temporaryDirectory.appendingPathComponent("sketchybar-runtime", isDirectory: true).path
  do {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  } catch {
    fputs("Could not create private runtime directory\n", stderr)
    exit(2)
  }
  var information = stat()
  guard lstat(path, &information) == 0,
        information.st_uid == getuid(),
        information.st_mode & S_IFMT == S_IFDIR else {
    fputs("Unsafe calendar runtime directory\n", stderr)
    exit(2)
  }
  guard chmod(path, 0o700) == 0,
        lstat(path, &information) == 0,
        information.st_uid == getuid(),
        information.st_mode & S_IFMT == S_IFDIR,
        information.st_mode & 0o777 == 0o700 else {
    fputs("Could not secure calendar runtime directory\n", stderr)
    exit(2)
  }
  return path
}()
private let instanceSuffix: String = {
  guard let value = ProcessInfo.processInfo.environment["SKETCHYBAR_CALENDAR_PANEL_INSTANCE"],
        !value.isEmpty,
        value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-" || $0 == "_" }) else { return "" }
  return "." + value
}()
private let pidPath = runtimeDirectory + "/calendar-panel.\(getuid())\(instanceSuffix).pid"
private let lockPath = pidPath + ".lock"
private var singletonDescriptor: Int32 = -1

private func lockDescriptorChecks(descriptor: Int32, path: String, expectedPID: pid_t) -> [String: Bool] {
  let descriptorNonnegative = descriptor >= 0
  let descriptorOpen = descriptorNonnegative && Darwin.fcntl(descriptor, F_GETFD) >= 0
  var descriptorInfo = stat()
  let descriptorStat = descriptorOpen && fstat(descriptor, &descriptorInfo) == 0
  var pathInfo = stat()
  let pathStat = lstat(path, &pathInfo) == 0
  let descriptorRegular = descriptorStat && descriptorInfo.st_mode & S_IFMT == S_IFREG
  let pathRegular = pathStat && pathInfo.st_mode & S_IFMT == S_IFREG
  let sameDevice = descriptorStat && pathStat && descriptorInfo.st_dev == pathInfo.st_dev
  let sameInode = descriptorStat && pathStat && descriptorInfo.st_ino == pathInfo.st_ino
  let pidContents = pidInFile(path) == expectedPID
  var lockRetained = false
  if pathStat {
    let probe = Darwin.open(path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
    if probe >= 0 {
      errno = 0
      let result = flock(probe, LOCK_EX | LOCK_NB)
      lockRetained = result != 0 && (errno == EWOULDBLOCK || errno == EAGAIN)
      if result == 0 { _ = flock(probe, LOCK_UN) }
      _ = Darwin.close(probe)
    }
  }
  return [
    "fd_nonnegative": descriptorNonnegative,
    "fd_open": descriptorOpen,
    "fd_fstat": descriptorStat,
    "path_lstat": pathStat,
    "same_device": sameDevice,
    "same_inode": sameInode,
    "fd_uid": descriptorStat && descriptorInfo.st_uid == getuid(),
    "fd_regular": descriptorRegular,
    "fd_mode_0600": descriptorStat && descriptorInfo.st_mode & 0o777 == 0o600,
    "path_uid": pathStat && pathInfo.st_uid == getuid(),
    "path_regular": pathRegular,
    "path_mode_0600": pathStat && pathInfo.st_mode & 0o777 == 0o600,
    "pid_contents": pidContents,
    "exclusive_lock_retained": lockRetained,
  ]
}

private func currentLockDescriptorChecks() -> [String: Bool] {
  lockDescriptorChecks(descriptor: singletonDescriptor, path: lockPath, expectedPID: getpid())
}

private func executablePath(pid: pid_t) -> String? {
  var buffer = [CChar](repeating: 0, count: 4096)
  let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
  return length > 0 ? String(cString: buffer) : nil
}

private func isOwned(pid: pid_t) -> Bool {
  guard let running = executablePath(pid: pid) else { return false }
  let current = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
  return URL(fileURLWithPath: running).resolvingSymlinksInPath().path == current
}

private func pidInFile(_ path: String) -> pid_t? {
  guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
  return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
}

private func hardenedPIDFile(_ expectedPID: pid_t) -> Bool {
  var information = stat()
  return lstat(pidPath, &information) == 0 && information.st_uid == getuid() &&
    information.st_mode & S_IFMT == S_IFREG && information.st_mode & 0o777 == 0o600 &&
    pidInFile(pidPath) == expectedPID
}

private func ownedPID() -> pid_t? {
  guard let pid = pidInFile(pidPath), hardenedPIDFile(pid), isOwned(pid: pid) else {
    if pidInFile(pidPath) != nil { try? FileManager.default.removeItem(atPath: pidPath) }
    return nil
  }
  return pid
}

private func ownedLockPID() -> pid_t? {
  guard let pid = pidInFile(lockPath), isOwned(pid: pid) else { return nil }
  return pid
}

private func pidInDescriptor(_ descriptor: Int32) -> pid_t? {
  var bytes = [UInt8](repeating: 0, count: 64)
  let count = bytes.withUnsafeMutableBytes { buffer in
    pread(descriptor, buffer.baseAddress, buffer.count, 0)
  }
  guard count > 0, let text = String(bytes: bytes.prefix(Int(count)), encoding: .utf8) else { return nil }
  return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
}

private func hardenedLockDescriptor(_ descriptor: Int32, path: String = lockPath) -> Bool {
  var descriptorInfo = stat()
  var pathInfo = stat()
  return descriptor >= 0 && fstat(descriptor, &descriptorInfo) == 0 && lstat(path, &pathInfo) == 0 &&
    descriptorInfo.st_uid == getuid() && pathInfo.st_uid == getuid() &&
    descriptorInfo.st_mode & S_IFMT == S_IFREG && pathInfo.st_mode & S_IFMT == S_IFREG &&
    descriptorInfo.st_mode & 0o777 == 0o600 && pathInfo.st_mode & 0o777 == 0o600 &&
    descriptorInfo.st_dev == pathInfo.st_dev && descriptorInfo.st_ino == pathInfo.st_ino
}

// A PID is actionable only while the hardened instance lock is actively held,
// both lock metadata files agree, and the process is this exact executable.
private func lockedOwnerPID() -> pid_t? {
  let descriptor = Darwin.open(lockPath, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
  guard descriptor >= 0 else { return nil }
  defer { _ = Darwin.close(descriptor) }
  guard hardenedLockDescriptor(descriptor) else { return nil }
  errno = 0
  let result = flock(descriptor, LOCK_EX | LOCK_NB)
  if result == 0 {
    _ = flock(descriptor, LOCK_UN)
    return nil
  }
  guard errno == EWOULDBLOCK || errno == EAGAIN,
        let lockedPID = pidInDescriptor(descriptor),
        hardenedPIDFile(lockedPID),
        isOwned(pid: lockedPID) else { return nil }
  return lockedPID
}

private func cleanStaleInstanceMetadata() -> Bool {
  let descriptor = Darwin.open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
  guard descriptor >= 0 else { return false }
  defer { _ = Darwin.close(descriptor) }
  guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0, hardenedLockDescriptor(descriptor),
        flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return false }
  defer { _ = flock(descriptor, LOCK_UN) }
  guard ftruncate(descriptor, 0) == 0, fsync(descriptor) == 0 else { return false }
  try? FileManager.default.removeItem(atPath: pidPath)
  return true
}

private func lockActivelyHeld() -> Bool {
  let descriptor = Darwin.open(lockPath, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
  guard descriptor >= 0 else { return false }
  defer { _ = Darwin.close(descriptor) }
  guard hardenedLockDescriptor(descriptor) else { return true }
  errno = 0
  let result = flock(descriptor, LOCK_EX | LOCK_NB)
  if result == 0 {
    _ = flock(descriptor, LOCK_UN)
    return false
  }
  return errno == EWOULDBLOCK || errno == EAGAIN
}

private func waitForLockRelease(timeout: TimeInterval) -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if !lockActivelyHeld() { return true }
    usleep(20_000)
  }
  return !lockActivelyHeld()
}

private func terminateLockedOwnerAndWait(_ pid: pid_t) -> Bool {
  // Re-probe the active lock and both PID records immediately before each signal.
  guard lockedOwnerPID() == pid, isOwned(pid: pid) else { return false }
  guard kill(pid, SIGTERM) == 0 || errno == ESRCH else { return false }
  if waitForLockRelease(timeout: 0.75) { return cleanStaleInstanceMetadata() }
  guard lockedOwnerPID() == pid, isOwned(pid: pid), kill(pid, SIGKILL) == 0 || errno == ESRCH else { return false }
  guard waitForLockRelease(timeout: 0.25) else { return false }
  return cleanStaleInstanceMetadata()
}

@discardableResult
private func closeOwnedAndWait() -> Bool {
  let deadline = Date().addingTimeInterval(1.0)
  while Date() < deadline {
    if let pid = lockedOwnerPID() {
      return terminateLockedOwnerAndWait(pid)
    }
    if cleanStaleInstanceMetadata() { return true }
    usleep(20_000)
  }
  return false
}

private func reserveSingleton(path: String = lockPath, beforeHardenForTest: ((Int32) -> Void)? = nil) -> Bool {
  let descriptor = Darwin.open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
  guard descriptor >= 0 else { return false }
  var information = stat()
  guard fstat(descriptor, &information) == 0, information.st_uid == getuid(), information.st_mode & S_IFMT == S_IFREG else { _ = Darwin.close(descriptor); return false }
  guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { _ = Darwin.close(descriptor); return false }
  guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else { _ = flock(descriptor, LOCK_UN); _ = Darwin.close(descriptor); return false }
  beforeHardenForTest?(descriptor)
  guard hardenedLockDescriptor(descriptor, path: path) else { _ = flock(descriptor, LOCK_UN); _ = Darwin.close(descriptor); return false }
  guard ftruncate(descriptor, 0) == 0 else { _ = flock(descriptor, LOCK_UN); _ = Darwin.close(descriptor); return false }
  let value = "\(getpid())\n"
  let wrote = value.withCString { pointer in Darwin.write(descriptor, pointer, strlen(pointer)) }
  guard wrote == strlen(value) else { _ = flock(descriptor, LOCK_UN); _ = Darwin.close(descriptor); return false }
  _ = fsync(descriptor)
  singletonDescriptor = descriptor
  return true
}

private func writePID() throws {
  let temporary = pidPath + ".new." + UUID().uuidString
  var descriptor = Darwin.open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
  guard descriptor >= 0 else { throw POSIXError(.EIO) }
  defer {
    if descriptor >= 0 { _ = Darwin.close(descriptor) }
    _ = unlink(temporary)
  }
  guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else { throw POSIXError(.EIO) }
  var temporaryInfo = stat()
  guard fstat(descriptor, &temporaryInfo) == 0, temporaryInfo.st_uid == getuid(),
        temporaryInfo.st_mode & S_IFMT == S_IFREG, temporaryInfo.st_mode & 0o777 == 0o600 else { throw POSIXError(.EIO) }
  let value = "\(getpid())\n"
  let wroteAll = value.withCString { pointer -> Bool in
    let length = strlen(pointer)
    var offset = 0
    while offset < length {
      let wrote = Darwin.write(descriptor, UnsafeRawPointer(pointer).advanced(by: offset), length - offset)
      if wrote <= 0 { return false }
      offset += wrote
    }
    return true
  }
  guard wroteAll, fsync(descriptor) == 0 else { throw POSIXError(.EIO) }
  guard Darwin.close(descriptor) == 0 else { descriptor = -1; throw POSIXError(.EIO) }
  descriptor = -1
  guard rename(temporary, pidPath) == 0 else { throw POSIXError(.EIO) }
  var publishedInfo = stat()
  guard lstat(pidPath, &publishedInfo) == 0, publishedInfo.st_uid == getuid(),
        publishedInfo.st_mode & S_IFMT == S_IFREG, publishedInfo.st_mode & 0o777 == 0o600,
        publishedInfo.st_dev == temporaryInfo.st_dev, publishedInfo.st_ino == temporaryInfo.st_ino,
        hardenedPIDFile(getpid()) else { throw POSIXError(.EIO) }
}

private func clearPID() {
  if pidInFile(pidPath) == getpid() { try? FileManager.default.removeItem(atPath: pidPath) }
  if singletonDescriptor >= 0 {
    _ = ftruncate(singletonDescriptor, 0)
    _ = flock(singletonDescriptor, LOCK_UN)
    _ = Darwin.close(singletonDescriptor)
    singletonDescriptor = -1
  }
}

private var selfTestCleanupActions: [() -> Void] = []

private func registerSelfTestCleanup(_ action: @escaping () -> Void) {
  selfTestCleanupActions.append(action)
}

private func runSelfTestCleanup() {
  let actions = selfTestCleanupActions.reversed()
  selfTestCleanupActions.removeAll()
  for action in actions { action() }
}

func assertTest(_ condition: @autoclosure () -> Bool, _ message: String) {
  if !condition() {
    fputs("Self-test failed: \(message)\n", stderr)
    runSelfTestCleanup()
    exit(1)
  }
}

private func waitForRunning(_ provider: EventProvider, timeout: TimeInterval) -> pid_t? {
  let deadline = Date().addingTimeInterval(timeout)
  repeat {
    if let pid = provider.runningPIDForTests() { return pid }
    RunLoop.current.run(until: min(deadline, Date().addingTimeInterval(0.01)))
  } while Date() < deadline
  return provider.runningPIDForTests()
}

private func removeSelfTestTree(_ url: URL) {
  for _ in 0..<10 {
    try? FileManager.default.removeItem(at: url)
    if !FileManager.default.fileExists(atPath: url.path) { return }
    RunLoop.current.run(until: Date().addingTimeInterval(0.01))
  }
}

private func selfTest() {
  selfTestCleanupActions.removeAll()
  let descriptorDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("calendar-panel-descriptor-\(getpid())", isDirectory: true)
  removeSelfTestTree(descriptorDirectory)
  try! FileManager.default.createDirectory(at: descriptorDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  registerSelfTestCleanup { removeSelfTestTree(descriptorDirectory) }
  func createLockedDescriptor(_ path: String) -> Int32 {
    let descriptor = Darwin.open(path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    assertTest(descriptor >= 0, "descriptor fixture opens")
    assertTest(fchmod(descriptor, 0o600) == 0, "descriptor fixture mode")
    let text = "\(getpid())\n"
    let wrote = text.withCString { Darwin.write(descriptor, $0, strlen($0)) }
    assertTest(wrote == strlen(text), "descriptor fixture PID")
    assertTest(flock(descriptor, LOCK_EX | LOCK_NB) == 0, "descriptor fixture lock")
    return descriptor
  }

  let liveLockPath = descriptorDirectory.appendingPathComponent("live.lock").path
  let liveDescriptor = createLockedDescriptor(liveLockPath)
  registerSelfTestCleanup { _ = flock(liveDescriptor, LOCK_UN); _ = Darwin.close(liveDescriptor) }
  let liveDescriptorChecks = lockDescriptorChecks(descriptor: liveDescriptor, path: liveLockPath, expectedPID: getpid())
  assertTest(liveDescriptorChecks.values.allSatisfy { $0 }, "live lock descriptor identity")

  let closedLockPath = descriptorDirectory.appendingPathComponent("closed.lock").path
  let closedDescriptor = createLockedDescriptor(closedLockPath)
  _ = flock(closedDescriptor, LOCK_UN); _ = Darwin.close(closedDescriptor)
  let closedDescriptorChecks = lockDescriptorChecks(descriptor: closedDescriptor, path: closedLockPath, expectedPID: getpid())
  assertTest(closedDescriptorChecks["fd_open"] == false && closedDescriptorChecks["exclusive_lock_retained"] == false, "closed lock descriptor rejected")

  let reusedLockPath = descriptorDirectory.appendingPathComponent("reused.lock").path
  let reusedDescriptor = createLockedDescriptor(reusedLockPath)
  _ = flock(reusedDescriptor, LOCK_UN); _ = Darwin.close(reusedDescriptor)
  let replacementPath = descriptorDirectory.appendingPathComponent("replacement.lock").path
  let replacementDescriptor = createLockedDescriptor(replacementPath)
  var descriptorAtReusedNumber = replacementDescriptor
  if replacementDescriptor != reusedDescriptor {
    assertTest(dup2(replacementDescriptor, reusedDescriptor) == reusedDescriptor, "reused descriptor fixture dup2")
    _ = Darwin.close(replacementDescriptor)
    descriptorAtReusedNumber = reusedDescriptor
  }
  let reusedDescriptorChecks = lockDescriptorChecks(descriptor: descriptorAtReusedNumber, path: reusedLockPath, expectedPID: getpid())
  assertTest(reusedDescriptorChecks["fd_open"] == true && reusedDescriptorChecks["same_inode"] == false, "reused lock descriptor rejected")
  _ = flock(descriptorAtReusedNumber, LOCK_UN); _ = Darwin.close(descriptorAtReusedNumber)

  let wrongLockPath = descriptorDirectory.appendingPathComponent("wrong.lock").path
  let wrongOldPath = descriptorDirectory.appendingPathComponent("wrong-old.lock").path
  let wrongDescriptor = createLockedDescriptor(wrongLockPath)
  registerSelfTestCleanup { _ = flock(wrongDescriptor, LOCK_UN); _ = Darwin.close(wrongDescriptor) }
  assertTest(rename(wrongLockPath, wrongOldPath) == 0, "wrong inode fixture rename")
  let newPathDescriptor = createLockedDescriptor(wrongLockPath)
  registerSelfTestCleanup { _ = flock(newPathDescriptor, LOCK_UN); _ = Darwin.close(newPathDescriptor) }
  let wrongInodeChecks = lockDescriptorChecks(descriptor: wrongDescriptor, path: wrongLockPath, expectedPID: getpid())
  assertTest(wrongInodeChecks["same_device"] == true && wrongInodeChecks["same_inode"] == false && !wrongInodeChecks.values.allSatisfy { $0 }, "wrong lock inode rejected")

  let mainMapping = DisplayAnchorMapping(id: 1, cgBounds: CGRect(x: 0, y: 0, width: 1512, height: 982), appKitFrame: CGRect(x: 0, y: 0, width: 1512, height: 982))
  let mainAnchor = ProductionAnchorResolver.convert(CGRect(x: 1212, y: 0, width: 116, height: 32), mappings: [mainMapping])
  assertTest(mainAnchor?.anchor == CGRect(x: 1212, y: 950, width: 116, height: 32) && mainAnchor?.display == mainMapping.appKitFrame, "main display CG top-left converts to AppKit bottom-left")
  let negativeMapping = DisplayAnchorMapping(id: 2, cgBounds: CGRect(x: -1920, y: 0, width: 1920, height: 1080), appKitFrame: CGRect(x: -1920, y: -98, width: 1920, height: 1080))
  let negativeAnchor = ProductionAnchorResolver.convert(CGRect(x: -116, y: 0, width: 116, height: 32), mappings: [mainMapping, negativeMapping])
  assertTest(negativeAnchor?.anchor == CGRect(x: -116, y: 950, width: 116, height: 32) && negativeAnchor?.id == 2, "negative display origin converts through display-local coordinates")
  let stackedMapping = DisplayAnchorMapping(id: 3, cgBounds: CGRect(x: 0, y: -900, width: 1440, height: 900), appKitFrame: CGRect(x: 0, y: 982, width: 1440, height: 900))
  let stackedAnchor = ProductionAnchorResolver.convert(CGRect(x: 100, y: -900, width: 116, height: 32), mappings: [mainMapping, stackedMapping])
  assertTest(stackedAnchor?.anchor == CGRect(x: 100, y: 1850, width: 116, height: 32) && stackedAnchor?.id == 3, "vertically stacked display converts through its matching screen frame")
  let overlappingMapping = DisplayAnchorMapping(id: 4, cgBounds: mainMapping.cgBounds, appKitFrame: mainMapping.appKitFrame)
  assertTest(ProductionAnchorResolver.convert(CGRect(x: 1212, y: 0, width: 116, height: 32), mappings: [mainMapping, overlappingMapping]) == nil, "overlapping display matches fail closed")
  assertTest(ProductionAnchorResolver.convert(CGRect(x: 1400, y: 0, width: 116, height: 32), mappings: [mainMapping]) == nil, "out-of-display anchor fails closed")
  assertTest(ProductionAnchorResolver.convert(CGRect(x: 0, y: 0, width: 115, height: 32), mappings: [mainMapping]) == nil, "wrong production anchor size fails closed")
  assertTest(ProductionAnchorResolver.convert(CGRect(x: CGFloat.nan, y: 0, width: 116, height: 32), mappings: [mainMapping]) == nil, "non-finite production anchor fails closed")

  func resolvedID(_ resolution: ProductionAnchorResolution) -> CGDirectDisplayID? {
    if case let .success(_, _, id) = resolution { return id }
    return nil
  }
  func isPointerMismatch(_ resolution: ProductionAnchorResolution) -> Bool {
    if case .pointerMismatch = resolution { return true }
    return false
  }
  func isInvalidAnchor(_ resolution: ProductionAnchorResolution) -> Bool {
    if case .invalid = resolution { return true }
    return false
  }
  let mainCandidate = CGRect(x: 1212, y: 0, width: 116, height: 32)
  assertTest(resolvedID(ProductionAnchorResolver.select([mainCandidate], mappings: [mainMapping], pointer: CGPoint(x: 1270, y: 966))) == 1, "one-display candidate selects exact rect under AppKit pointer")
  let negativeCandidate = CGRect(x: -116, y: 0, width: 116, height: 32)
  assertTest(resolvedID(ProductionAnchorResolver.select([mainCandidate, negativeCandidate], mappings: [mainMapping, negativeMapping], pointer: CGPoint(x: -58, y: 966))) == 2, "two-display candidates select the exact rect under AppKit pointer")
  assertTest(isPointerMismatch(ProductionAnchorResolver.select([mainCandidate], mappings: [mainMapping], pointer: CGPoint(x: 100, y: 100))), "moved pointer has a distinct no-action result")
  assertTest(isPointerMismatch(ProductionAnchorResolver.select([mainCandidate, mainCandidate], mappings: [mainMapping], pointer: CGPoint(x: 1270, y: 966))), "duplicate candidate pointer ambiguity fails closed")
  assertTest(isInvalidAnchor(ProductionAnchorResolver.select([mainCandidate], mappings: [mainMapping, overlappingMapping], pointer: CGPoint(x: 1270, y: 966))), "mirrored display mapping ambiguity is invalid")
  let maximumCandidates = (0..<ProductionAnchorResolver.maximumCandidates).map { CGRect(x: CGFloat($0 * 80), y: 64, width: 116, height: 32) }
  assertTest(resolvedID(ProductionAnchorResolver.select(maximumCandidates, mappings: [mainMapping], pointer: CGPoint(x: 58, y: 902))) == 1, "bounded maximum candidate count remains selectable")
  assertTest(isInvalidAnchor(ProductionAnchorResolver.select(maximumCandidates + [mainCandidate], mappings: [mainMapping], pointer: CGPoint(x: 1270, y: 966))), "candidate count above maximum fails closed")

  let weakReservePath = descriptorDirectory.appendingPathComponent("weak-reserve.lock").path
  _ = FileManager.default.createFile(atPath: weakReservePath, contents: Data(), attributes: [.posixPermissions: 0o644])
  assertTest(reserveSingleton(path: weakReservePath), "same-user stale 0644 lock is repaired before reservation")
  var weakReserveInfo = stat()
  assertTest(lstat(weakReservePath, &weakReserveInfo) == 0 && weakReserveInfo.st_mode & 0o777 == 0o600 && hardenedLockDescriptor(singletonDescriptor, path: weakReservePath), "reserved lock is owner regular same-inode mode 0600")
  _ = ftruncate(singletonDescriptor, 0)
  _ = flock(singletonDescriptor, LOCK_UN)
  _ = Darwin.close(singletonDescriptor)
  singletonDescriptor = -1

  let swappedReservePath = descriptorDirectory.appendingPathComponent("swapped-reserve.lock").path
  let displacedReservePath = descriptorDirectory.appendingPathComponent("swapped-reserve-old.lock").path
  _ = FileManager.default.createFile(atPath: swappedReservePath, contents: Data(), attributes: [.posixPermissions: 0o600])
  let swappedAccepted = reserveSingleton(path: swappedReservePath, beforeHardenForTest: { _ in
    assertTest(rename(swappedReservePath, displacedReservePath) == 0, "reservation inode-swap fixture rename")
    let replacement = Darwin.open(swappedReservePath, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    assertTest(replacement >= 0, "reservation inode-swap replacement")
    _ = Darwin.close(replacement)
  })
  assertTest(!swappedAccepted && singletonDescriptor == -1, "wrong-inode reservation fails closed before singleton publication")

  let originalTimeZone = CalendarMath.calendar.timeZone
  CalendarMath.calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
  registerSelfTestCleanup { CalendarMath.calendar.timeZone = originalTimeZone }
  let springInterval = EventProvider.queryInterval(for: DayValue(year: 2026, month: 3, day: 8))
  let fallInterval = EventProvider.queryInterval(for: DayValue(year: 2026, month: 11, day: 1))
  assertTest(springInterval.end.timeIntervalSince(springInterval.start) == 23 * 3600, "spring DST exclusive day boundary")
  assertTest(fallInterval.end.timeIntervalSince(fallInterval.start) == 25 * 3600, "fall DST exclusive day boundary")
  assertTest(CalendarMath.value(springInterval.end) == DayValue(year: 2026, month: 3, day: 9), "exclusive next calendar day")

  let parserTokens = OutputTokens(record: "__REC__", property: "__PROP__", newline: "__NL__")
  let parserOutput = "__REC__Timed late__PROP__2026-08-03 at 15:45:00 -0700 - 16:15:00 -0700__PROP__url: https://zoom.us.evil.example/j/12__PROP__uid: uid-late\n" +
    "__REC__Birthday__PROP__2026-08-03__PROP__uid: uid-birthday\n" +
    "__REC__Morning sync__PROP__2026-08-03 at 09:30:00 -0700 - 10:45:00 -0700__PROP__notes: line one__NL__Join https://meet.google.com/abc-defg-hij.__PROP__uid: uid-morning\n"
  let parsedEvents = try! EventOutputParser.parse(parserOutput, selected: DayValue(year: 2026, month: 8, day: 3), tokens: parserTokens)
  assertTest(parsedEvents.map(\.title) == ["Birthday", "Morning sync", "Timed late"], "all-day then chronological deterministic sort")
  let parserRaceGroup = DispatchGroup()
  let parserRaceLock = NSLock()
  var parserRaceFailures = 0
  for _ in 0..<64 {
    parserRaceGroup.enter()
    DispatchQueue.global(qos: .utility).async {
      defer { parserRaceGroup.leave() }
      do {
        let raced = try EventOutputParser.parse(parserOutput, selected: DayValue(year: 2026, month: 8, day: 3), tokens: parserTokens)
        if raced.map(\.title) != ["Birthday", "Morning sync", "Timed late"] {
          parserRaceLock.lock(); parserRaceFailures += 1; parserRaceLock.unlock()
        }
      } catch {
        parserRaceLock.lock(); parserRaceFailures += 1; parserRaceLock.unlock()
      }
    }
  }
  parserRaceGroup.wait()
  assertTest(parserRaceFailures == 0, "concurrent parser workers use isolated date formatters")
  assertTest(parsedEvents[1].meetingURL?.host == "meet.google.com" && parsedEvents[2].meetingURL == nil, "safe meeting fallback and hostile suffix rejection")
  assertTest(MeetingLink.safe("https://us06web.zoom.us/j/12345678901?pwd=fixture&amp;b=value") != nil, "safe Zoom URL")
  assertTest(MeetingLink.safe("https://meet.google.com/abc-defg-hij") != nil, "safe Meet URL")
  assertTest(MeetingLink.safe("https://teams.microsoft.com/l/meetup-join/19%3ameeting") != nil, "safe Teams URL")
  assertTest(MeetingLink.safe("https://example.webex.com/meet/room") != nil, "safe Webex URL")
  for unsafe in ["http://meet.google.com/abc-defg-hij", "https://user@meet.google.com/abc-defg-hij", "https://zoom.us.evil.example/j/12", "https://meet.google.com/"] {
    assertTest(MeetingLink.safe(unsafe) == nil, "unsafe meeting URL rejected")
  }
  assertTest(CalendarText.title("  A\nB\u{0085}\u{202E}\u{E000} C  ") == "A B C", "calendar text strips controls bidi and private use")
  let hugeSanitizedTitle = CalendarText.title(String(repeating: "界", count: 2000))!
  assertTest(hugeSanitizedTitle.count == 256 && hugeSanitizedTitle.utf8.count <= 1024, "calendar title grapheme and byte bounds")
  assertTest(EventOutputParser.decode(Data([0xff, 0xfe])) == nil, "invalid UTF-8 rejected")
  do {
    _ = try EventOutputParser.parse(String(repeating: "x", count: EventOutputParser.maximumOutputBytes + 1), selected: DayValue(year: 2026, month: 8, day: 3), tokens: parserTokens)
    assertTest(false, "output overflow must fail visibly")
  } catch {}

  let boundaryOutput =
    "__REC__Ends boundary__PROP__2026-08-02 at 23:00:00 -0700 - 2026-08-03 at 00:00:00 -0700__PROP__uid: boundary-end\\n" +
    "__REC__Starts boundary__PROP__2026-08-04 at 00:00:00 -0700 - 01:00:00 -0700__PROP__uid: boundary-start\\n" +
    "__REC__Spanning__PROP__2026-08-02 at 23:30:00 -0700 - 2026-08-03 at 00:30:00 -0700__PROP__uid: boundary-span\\n" +
    "__REC__Inside__PROP__2026-08-03 at 12:00:00 -0700 - 12:30:00 -0700__PROP__uid: boundary-inside\\n"
  let boundaryEvents = try! EventOutputParser.parse(boundaryOutput, selected: DayValue(year: 2026, month: 8, day: 3), tokens: parserTokens)
  assertTest(boundaryEvents.map(\.title) == ["Spanning", "Inside"], "exact boundary exclusion and spanning inclusion")

  let reorderedOutput = parserTokens.record + parserOutput.components(separatedBy: parserTokens.record).dropFirst().reversed().joined(separator: parserTokens.record)
  let reorderedEvents = try! EventOutputParser.parse(reorderedOutput, selected: DayValue(year: 2026, month: 8, day: 3), tokens: parserTokens)
  assertTest(reorderedEvents.map(\.identity) == parsedEvents.map(\.identity), "provider reorder preserves stable occurrence identities")
  let recurringA = EventOccurrence(uid: "series", title: "Recurring", start: Date(timeIntervalSince1970: 1000), end: Date(timeIntervalSince1970: 1100), allDay: false, meetingURL: nil)
  let recurringB = EventOccurrence(uid: "series", title: "Recurring", start: Date(timeIntervalSince1970: 2000), end: Date(timeIntervalSince1970: 2100), allDay: false, meetingURL: nil)
  assertTest(recurringA.identity != recurringB.identity, "recurrence start distinguishes stable identity")
  let normalized = [
    EventOccurrence(uid: "c", title: "Éclair", start: Date(timeIntervalSince1970: 3000), end: Date(timeIntervalSince1970: 3100), allDay: false, meetingURL: nil),
    EventOccurrence(uid: "a", title: "e\u{301}clair", start: Date(timeIntervalSince1970: 3000), end: Date(timeIntervalSince1970: 3100), allDay: false, meetingURL: nil),
    EventOccurrence(uid: "b", title: "ECLAIR", start: Date(timeIntervalSince1970: 3000), end: Date(timeIntervalSince1970: 3100), allDay: false, meetingURL: nil),
  ]
  let normalizedSorted = EventOrdering.sorted(normalized)
  assertTest(normalizedSorted.map(\.identity) == normalized.map(\.identity).sorted(), "fixed normalization uses stable identity tie-break")

  let phaseNow = Date(timeIntervalSince1970: 10_000)
  let endedAtNow = EventOccurrence(uid: "ended", title: "Ended", start: phaseNow.addingTimeInterval(-60), end: phaseNow, allDay: false, meetingURL: nil)
  let startsAtNow = EventOccurrence(uid: "active", title: "Active", start: phaseNow, end: phaseNow.addingTimeInterval(60), allDay: false, meetingURL: nil)
  let upcoming = EventOccurrence(uid: "upcoming", title: "Upcoming", start: phaseNow.addingTimeInterval(60), end: phaseNow.addingTimeInterval(120), allDay: false, meetingURL: nil)
  assertTest(EventPhase.value(for: endedAtNow, now: phaseNow) == .ended, "end equals now is ended")
  assertTest(EventPhase.value(for: startsAtNow, now: phaseNow) == .ongoing, "start equals now is ongoing")
  assertTest(EventPhase.value(for: upcoming, now: phaseNow) == .upcoming, "future event is upcoming")
  let allDayTokens = OutputTokens(record: "__RAW_REC__", property: "__RAW_PROP__", newline: "__RAW_NL__")
  let allDayRaw = "__RAW_REC__Multi-day raw__RAW_PROP__2026-08-20 - 2026-08-22__RAW_PROP__uid: raw-multi-day"
  let allDaySelectedDays = [20, 21, 22].map { try! EventOutputParser.parse(allDayRaw, selected: DayValue(year: 2026, month: 8, day: $0), tokens: allDayTokens) }
  let allDayExcluded = try! EventOutputParser.parse(allDayRaw, selected: DayValue(year: 2026, month: 8, day: 23), tokens: allDayTokens)
  assertTest(allDaySelectedDays.allSatisfy { events in
    events.count == 1 && CalendarMath.calendar.dateComponents([.day], from: events[0].start, to: events[0].end).day == 3
  }, "raw inclusive all-day range overlaps all three displayed calendar days")
  assertTest(Set(allDaySelectedDays.compactMap { $0.first?.identity }).count == 1 && allDayExcluded.isEmpty, "raw multi-day identity is stable and exclusive end is excluded")
  assertTest(CalendarPanelController.accessibilityDetail(for: allDaySelectedDays[1][0], selected: DayValue(year: 2026, month: 8, day: 21), now: CalendarMath.date(DayValue(year: 2026, month: 8, day: 21))).contains("Duration 3 days. In progress."), "raw multi-day all-day speech uses calendar-day duration")
  let singleAllDayRaw = "__RAW_REC__Single raw__RAW_PROP__2026-08-20__RAW_PROP__uid: raw-single-day"
  let singleAllDay = try! EventOutputParser.parse(singleAllDayRaw, selected: DayValue(year: 2026, month: 8, day: 20), tokens: allDayTokens)
  assertTest(singleAllDay.count == 1 && CalendarMath.calendar.dateComponents([.day], from: singleAllDay[0].start, to: singleAllDay[0].end).day == 1, "single-date all-day output remains one calendar day")
  let DSTAllDayRaw = "__RAW_REC__DST raw__RAW_PROP__2026-03-07 - 2026-03-09__RAW_PROP__uid: raw-dst-day"
  let DSTAllDay = try! EventOutputParser.parse(DSTAllDayRaw, selected: DayValue(year: 2026, month: 3, day: 9), tokens: allDayTokens)
  let DSTExcluded = try! EventOutputParser.parse(DSTAllDayRaw, selected: DayValue(year: 2026, month: 3, day: 10), tokens: allDayTokens)
  assertTest(DSTAllDay.count == 1 && CalendarMath.calendar.dateComponents([.day], from: DSTAllDay[0].start, to: DSTAllDay[0].end).day == 3 && DSTExcluded.isEmpty, "DST raw all-day range includes final displayed day and excludes following midnight")
  assertTest(CalendarPanelController.accessibilityDetail(for: DSTAllDay[0], selected: DayValue(year: 2026, month: 3, day: 9), now: CalendarMath.date(DayValue(year: 2026, month: 3, day: 9))).contains("Duration 3 days. In progress."), "DST all-day speech keeps calendar-day duration")

  let safeMeeting = MeetingLink.safe("https://meet.google.com/abc-defg-hij")!
  let actionable = EventOccurrence(uid: "action", title: "Action", start: phaseNow, end: phaseNow.addingTimeInterval(60), allDay: false, meetingURL: safeMeeting)
  let successOpener = RecordingCalendarOpener(URLResults: [true])
  assertTest(successOpener.URLs.isEmpty && successOpener.calendarCount == 0, "event action never opens before click")
  EventActionRouter.perform(actionable, opener: successOpener)
  assertTest(successOpener.URLs.count == 1 && successOpener.calendarCount == 0, "safe URL opens once")
  let failureOpener = RecordingCalendarOpener(URLResults: [false])
  EventActionRouter.perform(actionable, opener: failureOpener)
  assertTest(failureOpener.URLs.count == 1 && failureOpener.calendarCount == 1, "safe URL failure falls back once")
  let fallbackOpener = RecordingCalendarOpener(URLResults: [])
  EventActionRouter.perform(EventOccurrence(uid: "fallback", title: "Fallback", start: phaseNow, end: phaseNow.addingTimeInterval(60), allDay: false, meetingURL: nil), opener: fallbackOpener)
  assertTest(fallbackOpener.URLs.isEmpty && fallbackOpener.calendarCount == 1, "absent or unsafe URL opens Calendar directly")
  do {
    _ = try EventOutputParser.parse("__REC__Broken only title", selected: DayValue(year: 2026, month: 8, day: 3), tokens: parserTokens)
    assertTest(false, "partial record must fail visibly")
  } catch {}
  do {
    _ = try EventOutputParser.parse("__REC__Title__PROP__2026-08-03__PROP__notes: collision__PROP__orphan__PROP__uid: uid-collision", selected: DayValue(year: 2026, month: 8, day: 3), tokens: parserTokens)
    assertTest(false, "separator collision must fail visibly")
  } catch {}
  for malformedSentinel in [
    "__REC____REC__Title__PROP__2026-08-03__PROP__uid: adjacent",
    "__REC__Title__REC__Injected__PROP__2026-08-03__PROP__uid: title-token",
    "__REC__Title__PROP__2026-08-03__PROP__notes: before__REC__after__PROP__uid: property-token",
  ] {
    do {
      _ = try EventOutputParser.parse(malformedSentinel, selected: DayValue(year: 2026, month: 8, day: 3), tokens: parserTokens)
      assertTest(false, "record sentinel collision must fail visibly")
    } catch {}
  }
  for invalidDay in ["2025-02-29", "2026-00-01", "2026-13-01", "2026-08-00", "2026-08-32", "9999-01-01"] {
    do {
      _ = try EventOutputParser.parse("__REC__Invalid day__PROP__\(invalidDay)__PROP__uid: invalid-day", selected: DayValue(year: 2026, month: 8, day: 3), tokens: parserTokens)
      assertTest(false, "invalid Gregorian date must fail visibly")
    } catch {}
  }
  do {
    let hugeTitle = String(repeating: "x", count: EventOutputParser.maximumRawPropertyBytes + 1)
    _ = try EventOutputParser.parse("__REC__\(hugeTitle)__PROP__2026-08-03__PROP__uid: huge-title", selected: DayValue(year: 2026, month: 8, day: 3), tokens: parserTokens)
    assertTest(false, "huge raw title must fail visibly")
  } catch {}
  do {
    let records = (0...EventOutputParser.maximumRecords).map { "__REC__T\($0)__PROP__2026-08-03__PROP__uid: u\($0)" }.joined()
    _ = try EventOutputParser.parse(records, selected: DayValue(year: 2026, month: 8, day: 3), tokens: parserTokens)
    assertTest(false, "record count overflow must fail visibly")
  } catch {}
  do {
    let duplicate = "__REC__One__PROP__2026-08-03 at 09:00:00 -0700 - 09:30:00 -0700__PROP__uid: duplicate" +
      "__REC__Two__PROP__2026-08-03 at 09:00:00 -0700 - 09:30:00 -0700__PROP__uid: duplicate"
    _ = try EventOutputParser.parse(duplicate, selected: DayValue(year: 2026, month: 8, day: 3), tokens: parserTokens)
    assertTest(false, "duplicate occurrence identity must fail visibly")
  } catch {}

  let december = CalendarMath.shifted(year: 2026, month: 1, by: -1)
  assertTest(december.0 == 2025 && december.1 == 12, "December boundary")
  let january = CalendarMath.shifted(year: 2026, month: 12, by: 1)
  assertTest(january.0 == 2027 && january.1 == 1, "January boundary")
  let minimum = CalendarMath.shifted(year: 1900, month: 1, by: -1)
  let maximum = CalendarMath.shifted(year: 2200, month: 12, by: 1)
  assertTest(minimum.0 == 1900 && minimum.1 == 1, "minimum year clamp")
  assertTest(maximum.0 == 2200 && maximum.1 == 12, "maximum year clamp")
  let leap = CalendarMath.cells(year: 2028, month: 2)
  assertTest(leap.contains { $0.date == DayValue(year: 2028, month: 2, day: 29) && $0.isInMonth }, "2028 leap day")
  let ordinary = CalendarMath.cells(year: 2027, month: 2)
  assertTest(!ordinary.contains { $0.date == DayValue(year: 2027, month: 2, day: 29) && $0.isInMonth }, "2027 no leap day")
  let august = CalendarMath.cells(year: 2026, month: 8)
  assertTest(august.count == 42 && august[0].date.key == "2026-07-26" && august[6].date.key == "2026-08-01" && august[41].date.key == "2026-09-05", "42-cell mapping")
  let gate = GenerationGate(); let first = gate.begin(); let second = gate.begin()
  assertTest(!gate.accepts(first) && gate.accepts(second), "out-of-order generation guard")

  let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
  let right = CalendarPanelController.panelOrigin(anchor: CGRect(x: 1490, y: 950, width: 22, height: 32), display: display)
  let left = CalendarPanelController.panelOrigin(anchor: CGRect(x: -20, y: 950, width: 20, height: 32), display: display)
  let secondary = CalendarPanelController.panelOrigin(anchor: CGRect(x: -1440, y: 850, width: 40, height: 32), display: CGRect(x: -1440, y: -120, width: 1440, height: 900))
  assertTest(right.x + CalendarPanelController.panelSize.width <= display.maxX - 8, "right-edge clamp")
  assertTest(left.x >= display.minX + 8, "left-edge clamp")
  assertTest(secondary.x >= -1432 && secondary.y >= -112, "secondary-display clamp")

  let pointerDisplay = CGRect(x: 0, y: 0, width: 1512, height: 982)
  let fractionalPointer = CGPoint(x: 735.39453125, y: 828.73828125)
  let aligned1x = CalendarPanelController.backingAlignedPoint(fractionalPointer, scale: 1)
  let aligned2x = CalendarPanelController.backingAlignedPoint(fractionalPointer, scale: 2)
  assertTest(aligned1x == CGPoint(x: 735, y: 829), "fractional 1x alignment")
  assertTest(aligned2x == CGPoint(x: 735.5, y: 828.5), "fractional 2x alignment")
  let fractional1x = CalendarPanelController.pointerTestGeometry(point: aligned1x, display: pointerDisplay)
  let fractional2x = CalendarPanelController.pointerTestGeometry(point: aligned2x, display: pointerDisplay)
  assertTest(fractional1x != nil && fractional1x!.host.contains(fractionalPointer), "1x aligned host retains raw pointer")
  assertTest(fractional2x != nil && fractional2x!.host.contains(fractionalPointer), "2x aligned host retains raw pointer")
  assertTest((fractional1x!.panel.minX).rounded() == fractional1x!.panel.minX && (fractional1x!.panel.minY).rounded() == fractional1x!.panel.minY, "1x panel on backing pixels")
  assertTest((fractional2x!.panel.minX * 2).rounded() == fractional2x!.panel.minX * 2 && (fractional2x!.panel.minY * 2).rounded() == fractional2x!.panel.minY * 2, "2x panel on backing pixels")
  let unalignedPanel = CalendarPanelController.pointerTestGeometry(point: fractionalPointer, display: pointerDisplay)!.panel
  assertTest((unalignedPanel.minX * 2).rounded() != unalignedPanel.minX * 2 || (unalignedPanel.minY * 2).rounded() != unalignedPanel.minY * 2, "raw fractional panel exposes backing mismatch")

  let pointer = CGPoint(x: 756, y: 800)
  let pointerGeometry = CalendarPanelController.pointerTestGeometry(point: pointer, display: pointerDisplay)
  assertTest(pointerGeometry != nil && pointerGeometry!.host.contains(pointer), "valid pointer geometry")
  assertTest(abs((pointerGeometry!.panel.maxY + 4) - pointerGeometry!.host.minY) < 0.01, "exact pointer host gap")
  assertTest(CalendarPanelController.pointerTestGeometry(point: CGPoint(x: 756, y: 300), display: pointerDisplay) == nil, "insufficient vertical room")
  let leftPointer = CGPoint(x: 100, y: 800)
  let rightPointer = CGPoint(x: 1400, y: 800)
  let leftGeometry = CalendarPanelController.pointerTestGeometry(point: leftPointer, display: pointerDisplay)
  let rightGeometry = CalendarPanelController.pointerTestGeometry(point: rightPointer, display: pointerDisplay)
  assertTest(leftGeometry != nil && leftGeometry!.panel.minX == 8 && leftGeometry!.panel.minX <= leftPointer.x, "left clamp keeps pointer x in panel")
  assertTest(rightGeometry != nil && rightGeometry!.panel.maxX == 1504 && rightGeometry!.panel.maxX >= rightPointer.x, "right clamp keeps pointer x in panel")
  let movedPointer = CGPoint(x: pointer.x + 100, y: pointer.y)
  assertTest(PanelApplication.shouldOrder(point: pointer, host: pointerGeometry!.host), "pre-order stationary pointer")
  assertTest(!PanelApplication.shouldOrder(point: movedPointer, host: pointerGeometry!.host), "pre-order moved pointer abort")
  assertTest(!PanelApplication.shouldPauseDismissal(isKey: false, hasAccessibilityFocus: false), "ordinary pointer dismissal remains active")
  assertTest(PanelApplication.shouldPauseDismissal(isKey: true, hasAccessibilityFocus: false), "key panel pauses pointer dismissal")
  assertTest(PanelApplication.shouldPauseDismissal(isKey: false, hasAccessibilityFocus: true), "AX-focused descendant pauses pointer dismissal")
  assertTest(PanelApplication.deactivationOverridesPointerPause(), "explicit application deactivation overrides pointer-only pause")
  let mixedSectionPadding = CalendarPanelController.alignedBottomPadding(documentHeight: 200, viewportHeight: 137.5, boundaries: [0, 18, 62, 106, 124, 168])
  assertTest(mixedSectionPadding == 43.5 && mixedSectionPadding < 44, "mixed-section alignment padding stays below one event row")
  assertTest(CalendarPanelController.alignedBottomPadding(documentHeight: 200, viewportHeight: 200, boundaries: [0, 18]) == 0, "non-scrolling alignment adds no padding")
  let focus = FrontFocus(pid: 10, bundle: "test", windowID: 20, windowTitle: "window", windowBounds: CGRect(x: 1, y: 2, width: 3, height: 4))
  assertTest(PanelApplication.validLaunch(point: pointer, host: pointerGeometry!.host, panel: pointerGeometry!.panel, expectedPanel: pointerGeometry!.panel,
                                         display: pointerDisplay, visibleWindows: 1, processAlive: true, pidOwned: true, lockOwned: true, descriptorOwned: true,
                                         focus: focus, expectedFocus: focus), "valid post-order report")
  let wrongHeightPanel = CGRect(x: pointerGeometry!.panel.minX, y: pointerGeometry!.panel.minY - 8,
                                width: pointerGeometry!.panel.width, height: pointerGeometry!.panel.height + 8)
  assertTest(!PanelApplication.validLaunch(point: pointer, host: pointerGeometry!.host, panel: wrongHeightPanel, expectedPanel: pointerGeometry!.panel,
                                          display: pointerDisplay, visibleWindows: 1, processAlive: true, pidOwned: true, lockOwned: true, descriptorOwned: true,
                                          focus: focus, expectedFocus: focus), "controller expected height rejects wrong observed height")
  assertTest(!PanelApplication.validLaunch(point: movedPointer, host: pointerGeometry!.host, panel: pointerGeometry!.panel, expectedPanel: pointerGeometry!.panel,
                                          display: pointerDisplay, visibleWindows: 1, processAlive: true, pidOwned: true, lockOwned: true, descriptorOwned: true,
                                          focus: focus, expectedFocus: focus), "no success report after pointer move")
  assertTest(!PanelApplication.validLaunch(point: pointer, host: pointerGeometry!.host, panel: pointerGeometry!.panel, expectedPanel: pointerGeometry!.panel,
                                          display: pointerDisplay, visibleWindows: 1, processAlive: true, pidOwned: false, lockOwned: true, descriptorOwned: true,
                                          focus: focus, expectedFocus: focus), "unowned PID cannot report success")
  assertTest(!PanelApplication.validLaunch(point: pointer, host: pointerGeometry!.host, panel: pointerGeometry!.panel, expectedPanel: pointerGeometry!.panel,
                                          display: pointerDisplay, visibleWindows: 1, processAlive: true, pidOwned: true, lockOwned: false, descriptorOwned: true,
                                          focus: focus, expectedFocus: focus), "unowned lock cannot report success")
  let changedBounds = FrontFocus(pid: 10, bundle: "test", windowID: 20, windowTitle: "window", windowBounds: CGRect(x: 2, y: 2, width: 3, height: 4))
  assertTest(!PanelApplication.validLaunch(point: pointer, host: pointerGeometry!.host, panel: pointerGeometry!.panel, expectedPanel: pointerGeometry!.panel,
                                          display: pointerDisplay, visibleWindows: 1, processAlive: true, pidOwned: true, lockOwned: true, descriptorOwned: true,
                                          focus: changedBounds, expectedFocus: focus), "front window bounds change cannot report success")

  do { _ = try EventProvider(icalBuddy: "/bin/false", fixturePath: "/definitely/missing/calendar-fixture.json"); assertTest(false, "invalid fixture must fail") }
  catch { }

  let fixturePublishPath = descriptorDirectory.appendingPathComponent("publish-race.json")
  try! #"{"schemaVersion":1,"days":{"2026-08-03":{"events":[]}}}"#.write(to: fixturePublishPath, atomically: true, encoding: .utf8)
  let fixturePublishReady = DispatchSemaphore(value: 0)
  let fixturePublishRelease = DispatchSemaphore(value: 0)
  let fixturePublishProvider = try! EventProvider(icalBuddy: "/bin/false", fixturePath: fixturePublishPath.path, beforeFixturePublish: {
    fixturePublishReady.signal()
    _ = fixturePublishRelease.wait(timeout: .now() + 2)
  })
  var fixturePublishCompleted = false
  fixturePublishProvider.query(DayValue(year: 2026, month: 8, day: 3)) { _ in fixturePublishCompleted = true }
  assertTest(fixturePublishReady.wait(timeout: .now() + 2) == .success, "fixture reaches pre-publish cancellation barrier")
  fixturePublishProvider.cancel()
  fixturePublishRelease.signal()
  RunLoop.current.run(until: Date().addingTimeInterval(0.05))
  assertTest(!fixturePublishCompleted, "cancelled fixture cannot publish after final main-queue identity check")

  let providerSelected = DayValue(year: 2026, month: 8, day: 17)
  let providerInterval = EventProvider.queryInterval(for: providerSelected)
  let providerEventFormatter = DateFormatter()
  providerEventFormatter.locale = Locale(identifier: "en_US_POSIX")
  providerEventFormatter.calendar = Calendar(identifier: .gregorian)
  providerEventFormatter.dateFormat = "yyyy-MM-dd 'at' HH:mm:ss Z"
  let providerQueryFormatter = DateFormatter()
  providerQueryFormatter.locale = Locale(identifier: "en_US_POSIX")
  providerQueryFormatter.calendar = Calendar(identifier: .gregorian)
  providerQueryFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
  let providerCarriedRange = "\(providerEventFormatter.string(from: providerInterval.start.addingTimeInterval(-3600))) - \(providerEventFormatter.string(from: providerInterval.start.addingTimeInterval(3600)))"
  let providerEndBoundaryRange = "\(providerEventFormatter.string(from: providerInterval.start.addingTimeInterval(-7200))) - \(providerEventFormatter.string(from: providerInterval.start))"
  let providerStartBoundaryRange = "\(providerEventFormatter.string(from: providerInterval.end)) - \(providerEventFormatter.string(from: providerInterval.end.addingTimeInterval(3600)))"
  let expectedProviderStartArgument = "eventsFrom:\(providerQueryFormatter.string(from: providerInterval.start))"
  let expectedProviderEndArgument = "to:\(providerQueryFormatter.string(from: providerInterval.end))"
  let fakeProviderReport = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("calendar-panel-provider-args-\(getpid()).txt")
  let fakeProviderScript = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("calendar-panel-provider-\(getpid()).sh")
  let fakeProviderSource = #"""
#!/bin/sh
printf '%s\n' "$@" >"\#(fakeProviderReport.path)"
record=''
property=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    -b) shift; record=$1 ;;
    -ps) shift; property=$1 ;;
  esac
  shift
done
[ -n "$record" ] && [ -n "$property" ] || exit 2
property=${property#|}
property=${property%|}
emit() { printf '%s%s%s%s%suid: %s\n' "$record" "$1" "$property" "$2" "$property" "$3"; }
emit 'Carried from previous day' '\#(providerCarriedRange)' 'provider-carried'
emit 'Ends at selected boundary' '\#(providerEndBoundaryRange)' 'provider-end-boundary'
emit 'Starts at next boundary' '\#(providerStartBoundaryRange)' 'provider-start-boundary'
"""#
  try! fakeProviderSource.write(to: fakeProviderScript, atomically: true, encoding: .utf8)
  chmod(fakeProviderScript.path, 0o700)
  registerSelfTestCleanup { try? FileManager.default.removeItem(at: fakeProviderScript); try? FileManager.default.removeItem(at: fakeProviderReport) }
  let fakeProvider = try! EventProvider(icalBuddy: fakeProviderScript.path, fixturePath: nil, executionTimeout: 2.0, killGrace: 0.05)
  registerSelfTestCleanup { fakeProvider.cancelAndWaitForTests() }
  var providerResult: EventQueryResult?
  fakeProvider.query(providerSelected) { providerResult = $0 }
  let providerDeadline = Date().addingTimeInterval(3)
  while providerResult == nil && Date() < providerDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
  if case .events(let providerEvents) = providerResult {
    assertTest(providerEvents.count == 1 && providerEvents[0].title == "Carried from previous day", "provider path includes only strict selected-day overlaps")
  } else { assertTest(false, "synthetic provider path must return carried occurrence") }
  let providerArguments = (try? String(contentsOf: fakeProviderReport, encoding: .utf8)) ?? ""
  assertTest(providerArguments.components(separatedBy: .newlines).contains(expectedProviderStartArgument) && providerArguments.components(separatedBy: .newlines).contains(expectedProviderEndArgument), "provider path queries exact selected local day")
  assertTest(providerArguments.contains("|__SB_PROP_") && !providerArguments.components(separatedBy: .newlines).contains("-n") && !providerArguments.components(separatedBy: .newlines).contains("-li"), "provider path uses wrapped random separators without lossy limits")
  fakeProvider.cancelAndWaitForTests()

  let today = CalendarMath.value(Date())
  let future = CalendarMath.value(CalendarMath.calendar.date(byAdding: .day, value: 2, to: CalendarMath.date(today))!)
  let yesterday = CalendarMath.value(CalendarMath.calendar.date(byAdding: .day, value: -1, to: CalendarMath.date(today))!)
  let fixture = FixtureDocument(schemaVersion: 1, days: [
    today.key: FixtureDay(state: nil, delayMS: 150, events: (1...16).map {
      FixtureOccurrence(uid: "fixture-stale-\($0)", title: String(format: "Slow stale event %02d", $0), allDay: true,
                        start: nil, end: nil, url: nil, location: nil, notes: nil)
    }),
    future.key: FixtureDay(state: nil, delayMS: 5, events: [
      FixtureOccurrence(uid: "fixture-future", title: "Future all-day event", allDay: true, start: nil, end: nil,
                        url: nil, location: nil, notes: nil),
    ]),
  ])
  let fixtureURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("calendar-panel-self-test-\(getpid()).json")
  try! JSONEncoder().encode(fixture).write(to: fixtureURL, options: .atomic)
  registerSelfTestCleanup { try? FileManager.default.removeItem(at: fixtureURL) }
  let notificationRecorder = RecordingAccessibilityNotifier()
  let controller = try! CalendarPanelController(anchor: CGRect(x: 1212, y: 950, width: 116, height: 32), display: display, icalBuddy: "/bin/false", fixture: fixtureURL.path, selected: today, now: CalendarMath.date(future), accessibilityNotifier: notificationRecorder)
  registerSelfTestCleanup { controller.provider.cancelAndWaitForTests() }
  controller.content.layoutSubtreeIfNeeded()
  assertTest(notificationRecorder.createdCount == 0 && notificationRecorder.layoutCount == 0, "loading state emits no AX creation or layout announcements")

  let cellFrames = controller.dateButtons.map { $0.convert($0.bounds, to: controller.content) }
  assertTest(cellFrames.count == 42 && Set(cellFrames.map { "\($0.minX),\($0.minY)" }).count == 42, "42 unique cell frames")
  assertTest(cellFrames.allSatisfy { $0.width == 36 && $0.height == 32 }, "36 by 32 hit targets")
  for row in 0..<6 {
    let values = Array(cellFrames[(row * 7)..<(row * 7 + 7)])
    assertTest(values.map(\.minY).allSatisfy { $0 == values[0].minY }, "row y alignment")
    for column in 1..<7 { assertTest(values[column].minX - values[column - 1].maxX == 0, "no column gap or overlap") }
  }
  for row in 1..<6 { assertTest(cellFrames[row * 7 - 7].minY - cellFrames[row * 7].minY == 32, "no row gap or overlap") }
  let headerCenters = controller.weekdayLabels.map { $0.convert($0.bounds, to: controller.content).midX }
  let cellCenters = Array(cellFrames[0..<7]).map(\.midX)
  assertTest(headerCenters == cellCenters, "weekday and date centers")
  assertTest(controller.navButtons.count == 4, "four navigation controls")
  assertTest(Set(controller.navButtons.map { $0.accessibilityIdentifier() }).count == 4, "unique navigation identifiers")
  assertTest(Set(controller.dateButtons.map { $0.accessibilityIdentifier() }).count == 42, "unique date identifiers")
  assertTest(controller.today == future, "injected now controls today identity")
  assertTest(controller.panel.canBecomeKey && !controller.panel.isKeyWindow, "panel can become key without becoming key on construction")
  assertTest(controller.dateButtons.allSatisfy { $0.acceptsFirstResponder && $0.canBecomeKeyView && $0.needsPanelToBecomeKey }, "date controls support deterministic keyboard focus")
  assertTest((controller.navButtons + [controller.monthButton]).allSatisfy { $0.acceptsFirstResponder && $0.canBecomeKeyView && $0.needsPanelToBecomeKey }, "navigation controls support deterministic keyboard focus")
  assertTest(controller.dateButtons.allSatisfy { $0.focusRingMaskBounds == $0.bounds.insetBy(dx: 2, dy: 2) }, "focus masks stay inside date geometry")
  assertTest(controller.panel.initialFirstResponder === controller.dateButtons.first { $0.representedDate == today }, "selected date is initial responder")
  assertTest(controller.navButtons[0].nextKeyView === controller.navButtons[1] && controller.navButtons[1].nextKeyView === controller.monthButton && controller.monthButton.nextKeyView === controller.navButtons[2], "deterministic control key order")
  assertTest(controller.dateButtons.filter { $0.selectedForAccessibility }.count == 1, "one date exposes selected state")
  assertTest(controller.dateButtons.allSatisfy { (($0.accessibilityValue() as? NSNumber)?.boolValue ?? false) == $0.selectedForAccessibility }, "public radio AX values match selection state")
  assertTest(controller.dateButtons.allSatisfy { $0.accessibilityRole() == .radioButton }, "date controls expose public radio-button role")
  assertTest(controller.grid.accessibilityRole() == .radioGroup && (controller.grid.accessibilityLabel() ?? "").hasPrefix("Dates for "), "date grid exposes named radio group")
  assertTest(controller.panel.title == "Calendar" && controller.panel.accessibilityTitle() == "Calendar", "native panel has visible and AX title")
  assertTest(!controller.panel.autorecalculatesKeyViewLoop, "manual key loop cannot be replaced by AppKit")

  controller.select(DayValue(year: 2026, month: 2, day: 10))
  let sameCellBefore = controller.dateButtons.first { $0.representedDate == controller.selectedDate }
  let notificationCountBeforeSameCellShift = notificationRecorder.valueChangedCount
  controller.changeMonth(1)
  let sameCellAfter = controller.dateButtons.first { $0.representedDate == controller.selectedDate }
  assertTest(sameCellBefore === sameCellAfter && notificationRecorder.valueChangedCount == notificationCountBeforeSameCellShift + 1, "same reusable radio cell still posts value change across month shift")

  controller.viewYear = 2026; controller.viewMonth = 12; controller.changeMonth(1)
  assertTest(controller.viewYear == 2027 && controller.viewMonth == 1, "UI month year boundary")
  controller.viewYear = 1900; controller.viewMonth = 1; controller.changeMonth(-1)
  assertTest(controller.viewYear == 1900 && controller.viewMonth == 1, "UI minimum boundary")
  controller.viewYear = 2200; controller.viewMonth = 12; controller.changeMonth(1)
  assertTest(controller.viewYear == 2200 && controller.viewMonth == 12, "UI maximum boundary")
  assertTest(controller.monthButton.title.hasSuffix("↩") && controller.monthButton.accessibilityHelp() == "Return to Today" && (controller.monthButton.accessibilityLabel() ?? "").lowercased().contains("return to today"), "away month control offers today recovery with month context")
  controller.returnToToday()
  assertTest(controller.selectedDate == future && controller.viewYear == future.year && controller.viewMonth == future.month, "today recovery restores view and selection")
  assertTest(!controller.monthButton.title.hasSuffix("↩") && !(controller.monthButton.accessibilityLabel() ?? "").lowercased().contains("return"), "today recovery clears return state")
  controller.viewYear = 2200; controller.viewMonth = 12; controller.renderMonth()
  let lowerOverflow = CalendarMath.cells(year: 1900, month: 1)[0].date
  let upperOverflow = CalendarMath.cells(year: 2200, month: 12)[41].date
  assertTest(lowerOverflow.year == 1899 && upperOverflow.year == 2201, "boundary overflow dates remain representable")
  controller.viewYear = 2200; controller.viewMonth = 12; controller.select(upperOverflow)
  assertTest(controller.viewYear == 2200 && controller.viewMonth == 12 && controller.selectedDate == upperOverflow, "overflow selection cannot escape view bounds")

  controller.select(today)
  controller.select(future)
  RunLoop.current.run(until: Date().addingTimeInterval(0.08))
  assertTest(controller.detailState == "events" && controller.eventRows.count == 1 &&
             controller.eventRows[0].titleLabel.stringValue == "Future all-day event" &&
             controller.eventRows[0].detailLabel.stringValue == "All day · ONGOING", "rapid selection commits latest all-day result")
  assertTest(notificationRecorder.createdCount == 0 && notificationRecorder.layoutCount == 0, "pre-show final data queues AX notifications")
  controller.flushPendingAccessibilityNotifications()
  assertTest(notificationRecorder.createdCount == 2 && notificationRecorder.layoutCount == 1 && notificationRecorder.lastElementCount == 2, "show-time flush announces final section, row, and one group layout")
  controller.flushPendingAccessibilityNotifications()
  assertTest(notificationRecorder.createdCount == 2 && notificationRecorder.layoutCount == 1, "second show-time flush cannot duplicate AX notifications")
  assertTest(controller.eventRows[0].accessibilityLabel()?.contains("All-day event. Duration 1 day. In progress.") == true, "all-day AX speech includes duration and temporal phase")
  assertTest(controller.eventRows[0].accessibilityLabel()?.contains(" · ") == false, "AX speech excludes compact visual delimiters")
  assertTest(controller.eventDocument.accessibilityRole() == .group && (controller.eventDocument.accessibilityLabel() ?? "").hasPrefix("Events for "), "selected-day events expose named group")
  RunLoop.current.run(until: Date().addingTimeInterval(0.15))
  assertTest(controller.eventRows.count == 1 && controller.eventRows[0].titleLabel.stringValue == "Future all-day event" && controller.panel.frame.height == CalendarPanelController.panelSize.height, "cancelled stale result cannot overwrite or resize")
  let focusFirst = EventOccurrence(uid: "focus-first", title: "First", start: Date(timeIntervalSince1970: 100), end: Date(timeIntervalSince1970: 200), allDay: false, meetingURL: nil)
  let focusSecond = EventOccurrence(uid: "focus-second", title: "Second", start: Date(timeIntervalSince1970: 300), end: Date(timeIntervalSince1970: 400), allDay: false, meetingURL: nil)
  assertTest(CalendarPanelController.preferredFocusIdentity(previous: focusSecond.identity, events: [focusSecond, focusFirst]) == focusSecond.identity, "reordered refresh retains stable focused occurrence")
  assertTest(CalendarPanelController.preferredFocusIdentity(previous: "removed", events: [focusFirst, focusSecond]) == focusFirst.identity, "removed focused occurrence moves to first new row")
  assertTest(CalendarPanelController.preferredFocusIdentity(previous: focusSecond.identity, events: []) == nil, "empty refresh falls back to selected date")
  assertTest(CalendarPanelController.preferredFocusIdentity(previous: nil, events: [focusFirst, focusSecond]) == nil, "date-triggered refresh retains selected-date focus")
  let retainedLoadingIdentity = CalendarPanelController.restorationIdentity(pendingGeneration: 7, pendingIdentity: focusSecond.identity, acceptedGeneration: 7)
  assertTest(CalendarPanelController.preferredFocusIdentity(previous: retainedLoadingIdentity, events: [focusSecond, focusFirst]) == focusSecond.identity, "loading to final reorder restores retained identity")
  assertTest(CalendarPanelController.preferredFocusIdentity(previous: retainedLoadingIdentity, events: [focusFirst]) == focusFirst.identity, "loading to final removal chooses first new row")
  assertTest(CalendarPanelController.restorationIdentity(pendingGeneration: 7, pendingIdentity: focusSecond.identity, acceptedGeneration: 8) == nil, "superseded generation cannot restore old identity")
  assertTest(CalendarPanelController.shouldPreserveScroll(requested: future, lastFinal: future, focusedIdentity: focusSecond.identity), "same-day focused refresh preserves scroll")
  assertTest(!CalendarPanelController.shouldPreserveScroll(requested: future, lastFinal: today, focusedIdentity: focusSecond.identity), "new selected day resets scroll despite old row focus")
  controller.select(today)
  RunLoop.current.run(until: Date().addingTimeInterval(0.20))
  assertTest(controller.eventRows.count == 16 && controller.scrollView.contentView.bounds.minY == 0, "long selected day starts at top")
  controller.eventRows.last!.scrollIntoViewForKeyboardFocus()
  controller.scrollView.reflectScrolledClipView(controller.scrollView.contentView)
  assertTest(controller.eventDocument.visibleRect.contains(controller.eventRows.last!.frame) && controller.eventRows.last!.frame.height == 44, "keyboard focus path exposes complete last event row")
  controller.eventRows.first!.scrollIntoViewForKeyboardFocus()
  controller.scrollView.reflectScrolledClipView(controller.scrollView.contentView)
  assertTest(controller.eventDocument.visibleRect.contains(controller.eventRows.first!.frame) && controller.eventRows.first!.frame.height == 44, "keyboard focus path exposes complete first event row")
  controller.scrollToBottom()
  assertTest(controller.scrollView.contentView.bounds.minY > 0, "long selected day reaches bottom")
  controller.select(future)
  RunLoop.current.run(until: Date().addingTimeInterval(0.08))
  assertTest(controller.eventRows.count == 1 && controller.scrollView.contentView.bounds.minY == 0, "new selected day final list resets to top")

  controller.select(yesterday)
  RunLoop.current.run(until: Date().addingTimeInterval(0.02))
  assertTest(controller.detailState == "empty" && controller.eventRows.isEmpty, "past selected day remains queryable")
  controller.provider.cancel()

  let sleeper = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("calendar-panel-sleeper-\(getpid()).sh")
  try! "#!/bin/sh\nexec /bin/sleep 10\n".write(to: sleeper, atomically: true, encoding: .utf8)
  chmod(sleeper.path, 0o700)
  registerSelfTestCleanup { try? FileManager.default.removeItem(at: sleeper) }
  let timeoutProvider = try! EventProvider(icalBuddy: sleeper.path, fixturePath: nil, executionTimeout: 0.10, killGrace: 0.05)
  registerSelfTestCleanup { timeoutProvider.cancelAndWaitForTests() }
  var timeoutResult = false
  timeoutProvider.query(future) { result in if case .error = result { timeoutResult = true } }
  let timedPID = waitForRunning(timeoutProvider, timeout: 1.0)
  assertTest(timedPID != nil, "owned query process starts")
  RunLoop.current.run(until: Date().addingTimeInterval(0.35))
  assertTest(timeoutResult && (timedPID == nil || kill(timedPID!, 0) != 0), "query timeout terminates owned process")

  let cancelProvider = try! EventProvider(icalBuddy: sleeper.path, fixturePath: nil, executionTimeout: 5.0, killGrace: 0.05)
  registerSelfTestCleanup { cancelProvider.cancelAndWaitForTests() }
  cancelProvider.query(future) { _ in }
  let cancelledPID = waitForRunning(cancelProvider, timeout: 1.0)
  assertTest(cancelledPID != nil, "cancellable query starts")
  if ProcessInfo.processInfo.environment["CALENDAR_PANEL_SELF_TEST_FAIL_CLEANUP"] == "1" {
    guard let reportPath = ProcessInfo.processInfo.environment["CALENDAR_PANEL_SELF_TEST_PID_REPORT"],
          let cancelledPID else { assertTest(false, "deliberate cleanup report configuration"); return }
    do {
      try "\(cancelledPID)\n".write(to: URL(fileURLWithPath: reportPath), atomically: true, encoding: .utf8)
    } catch { assertTest(false, "deliberate cleanup PID report") }
    assertTest(false, "deliberate cleanup path")
  }
  cancelProvider.cancel()
  RunLoop.current.run(until: Date().addingTimeInterval(0.20))
  assertTest(cancelledPID == nil || kill(cancelledPID!, 0) != 0, "selection cancellation terminates owned process")

  let reachedPrelaunch = DispatchSemaphore(value: 0)
  let releasePrelaunch = DispatchSemaphore(value: 0)
  let barrierProvider = try! EventProvider(icalBuddy: sleeper.path, fixturePath: nil, executionTimeout: 5.0, killGrace: 0.05, prelaunchHook: {
    reachedPrelaunch.signal()
    _ = releasePrelaunch.wait(timeout: .now() + 1)
  })
  registerSelfTestCleanup { barrierProvider.cancelAndWaitForTests() }
  barrierProvider.query(future) { _ in }
  assertTest(reachedPrelaunch.wait(timeout: .now() + 1) == .success, "pre-launch barrier reached")
  barrierProvider.cancel()
  releasePrelaunch.signal()
  RunLoop.current.run(until: Date().addingTimeInterval(0.25))
  let stoppedPrelaunch = barrierProvider.stoppedPrelaunchPIDForTests()
  assertTest(stoppedPrelaunch != nil && kill(stoppedPrelaunch!, 0) != 0, "pre-launch cancellation stops process after run")

  let failedLaunchReady = DispatchSemaphore(value: 0)
  let failedLaunchRelease = DispatchSemaphore(value: 0)
  var failedLaunchCompleted = false
  let failedLaunchProvider = try! EventProvider(icalBuddy: "/definitely/missing/calendar-provider", fixturePath: nil, prelaunchHook: {
    failedLaunchReady.signal()
    _ = failedLaunchRelease.wait(timeout: .now() + 1)
  })
  failedLaunchProvider.query(future) { _ in failedLaunchCompleted = true }
  assertTest(failedLaunchReady.wait(timeout: .now() + 1) == .success, "failed-launch cancellation barrier reached")
  failedLaunchProvider.cancel()
  failedLaunchRelease.signal()
  RunLoop.current.run(until: Date().addingTimeInterval(0.10))
  assertTest(!failedLaunchCompleted, "cancelled process.run failure cannot publish a stale completion")
  failedLaunchProvider.cancelAndWaitForTests()
  runSelfTestCleanup()
  assertTest(!FileManager.default.fileExists(atPath: fixtureURL.path) && !FileManager.default.fileExists(atPath: sleeper.path) &&
             !FileManager.default.fileExists(atPath: descriptorDirectory.path), "self-test artifacts removed")
  print("Calendar panel self-test passed")
}

struct FrontFocus: Equatable {
  let pid: pid_t
  let bundle: String
  let windowID: Int
  let windowTitle: String
  let windowBounds: CGRect
}

func captureFrontFocus() -> FrontFocus {
  let front = NSWorkspace.shared.frontmostApplication
  let pid = front?.processIdentifier ?? -1
  let values = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
  let window = values.first {
    ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
  }
  let rawBounds = window?[kCGWindowBounds as String] as? [String: Any] ?? [:]
  let number: (String) -> CGFloat = { (rawBounds[$0] as? NSNumber).map { CGFloat(truncating: $0) } ?? 0 }
  let bounds = CGRect(x: number("X"), y: number("Y"), width: number("Width"), height: number("Height"))
  return FrontFocus(pid: pid, bundle: front?.bundleIdentifier ?? "",
                    windowID: window?[kCGWindowNumber as String] as? Int ?? -1,
                    windowTitle: window?[kCGWindowName as String] as? String ?? "",
                    windowBounds: bounds)
}

final class PanelApplication: NSObject, NSApplicationDelegate {
  let controller: CalendarPanelController
  let stateReport: String?
  let expectedFocus: FrontFocus
  var timer: Timer?
  var outsideSince: Date?
  var lastButtons = NSEvent.pressedMouseButtons
  var signalSource: DispatchSourceSignal?
  var screenObserver: NSObjectProtocol?
  var wakeObserver: NSObjectProtocol?
  var lastEscape = CGEventSource.keyState(.combinedSessionState, key: 53)

  init(controller: CalendarPanelController, stateReport: String?, expectedFocus: FrontFocus) {
    self.controller = controller
    self.stateReport = stateReport
    self.expectedFocus = expectedFocus
  }

  static func shouldOrder(point: CGPoint, host: CGRect) -> Bool { host.contains(point) }
  static func shouldPauseDismissal(isKey: Bool, hasAccessibilityFocus: Bool) -> Bool { isKey || hasAccessibilityFocus }
  static func deactivationOverridesPointerPause() -> Bool { true }

  static func launchChecks(point: CGPoint, host: CGRect, panel: CGRect, expectedPanel: CGRect, display: CGRect,
                           visibleWindows: Int, processAlive: Bool, pidOwned: Bool, lockOwned: Bool, descriptorOwned: Bool,
                           focus: FrontFocus, expectedFocus: FrontFocus) -> [String: Bool] {
    return [
      "pointer_in_host": host.contains(point),
      "pointer_x_in_panel": point.x >= panel.minX && point.x <= panel.maxX,
      "panel_height_valid": panel.height >= CalendarPanelController.panelSize.height && panel.height <= CalendarPanelController.maximumPreferredHeight,
      "panel_frame_exact": panel.equalTo(expectedPanel),
      "panel_inside_display": panel.minX >= display.minX + 8 && panel.maxX <= display.maxX - 8 &&
        panel.minY >= display.minY + 8 && panel.maxY <= display.maxY - 8,
      "exact_gap": abs((panel.maxY + 4) - host.minY) < 0.01,
      "no_overlap": !panel.intersects(host),
      "one_visible_window": visibleWindows == 1,
      "process_alive": processAlive,
      "pid_owned": pidOwned,
      "lock_owned": lockOwned,
      "descriptor_owned": descriptorOwned,
      "focus_bundle_equal": focus.bundle == expectedFocus.bundle,
      "focus_pid_equal": focus.pid == expectedFocus.pid,
      "focus_window_equal": focus.windowID == expectedFocus.windowID,
      "focus_title_equal": focus.windowTitle == expectedFocus.windowTitle,
      "focus_bounds_equal": focus.windowBounds == expectedFocus.windowBounds,
      "focus_equal": focus == expectedFocus,
    ]
  }

  static func validLaunch(point: CGPoint, host: CGRect, panel: CGRect, expectedPanel: CGRect, display: CGRect,
                          visibleWindows: Int, processAlive: Bool, pidOwned: Bool, lockOwned: Bool, descriptorOwned: Bool,
                          focus: FrontFocus, expectedFocus: FrontFocus) -> Bool {
    launchChecks(point: point, host: host, panel: panel, expectedPanel: expectedPanel, display: display,
                 visibleWindows: visibleWindows, processAlive: processAlive,
                 pidOwned: pidOwned, lockOwned: lockOwned, descriptorOwned: descriptorOwned,
                 focus: focus, expectedFocus: expectedFocus).values.allSatisfy { $0 }
  }

  private func rect(_ value: CGRect) -> [String: CGFloat] {
    ["x": value.minX, "y": value.minY, "width": value.width, "height": value.height]
  }

  private func writeFailure(_ phase: String, point: CGPoint, everOrdered: Bool, details: [String: Any] = [:]) {
    guard let stateReport else { return }
    let visibleWindows = NSApp.windows.filter { $0.isVisible }.count
    var value: [String: Any] = [
      "valid": false, "phase": phase, "pid": getpid(), "ever_ordered": everOrdered,
      "visible_now": visibleWindows > 0, "visible_windows": visibleWindows,
      "pointer": ["x": point.x, "y": point.y], "host": rect(controller.hostAnchor),
    ]
    value.merge(details) { _, replacement in replacement }
    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
      try? data.write(to: URL(fileURLWithPath: stateReport), options: .atomic)
    }
  }

  private func writeLaunchReport() {
    guard let stateReport else { return }
    let point = NSEvent.mouseLocation
    let visibleWindows = NSApp.windows.filter { $0.isVisible }.count
    let focus = captureFrontFocus()
    let display = controller.panel.screen?.frame ?? .zero
    let processAlive = kill(getpid(), 0) == 0
    let pidOwned = ownedPID() == getpid()
    let lockOwned = ownedLockPID() == getpid()
    let descriptorChecks = currentLockDescriptorChecks()
    let descriptorOwned = descriptorChecks.values.allSatisfy { $0 }
    let expectedPanel = controller.expectedPanelFrame()
    var checks = Self.launchChecks(point: point, host: controller.hostAnchor, panel: controller.panel.frame,
                                   expectedPanel: expectedPanel, display: display, visibleWindows: visibleWindows,
                                   processAlive: processAlive, pidOwned: pidOwned, lockOwned: lockOwned, descriptorOwned: descriptorOwned,
                                   focus: focus, expectedFocus: expectedFocus)
    for (name, passed) in descriptorChecks { checks["descriptor_\(name)"] = passed }
    let valid = checks.values.allSatisfy { $0 }
    guard valid else {
      let focusValue: (FrontFocus) -> [String: Any] = {
        ["bundle": $0.bundle, "pid": $0.pid, "window": $0.windowID, "title": $0.windowTitle, "bounds": self.rect($0.windowBounds)]
      }
      let observedPanel = controller.panel.frame
      let details: [String: Any] = [
        "checks": checks, "observed_panel": rect(observedPanel), "expected_panel": rect(expectedPanel),
        "observed_height": observedPanel.height, "expected_height": expectedPanel.height,
        "frame_delta": ["x": observedPanel.minX - expectedPanel.minX, "y": observedPanel.minY - expectedPanel.minY,
                        "width": observedPanel.width - expectedPanel.width, "height": observedPanel.height - expectedPanel.height],
        "gap_delta": (observedPanel.maxY + 4) - controller.hostAnchor.minY,
        "display": rect(display),
        "display_insets": ["left": observedPanel.minX - display.minX, "right": display.maxX - observedPanel.maxX,
                           "bottom": observedPanel.minY - display.minY, "top": display.maxY - observedPanel.maxY],
        "overlap": observedPanel.intersects(controller.hostAnchor),
        "observed_visible_windows_before_order_out": visibleWindows,
        "process_alive": processAlive, "pid_owned": pidOwned, "lock_owned": lockOwned, "descriptor_owned": descriptorOwned,
        "descriptor_checks": descriptorChecks,
        "observed_focus": focusValue(focus), "expected_focus": focusValue(expectedFocus),
      ]
      controller.panel.orderOut(nil)
      guard NSApp.windows.filter({ $0.isVisible }).isEmpty else { NSApp.terminate(nil); return }
      writeFailure("post_order_validation_failed", point: point, everOrdered: true, details: details)
      NSApp.terminate(nil)
      return
    }
    let value: [String: Any] = [
      "valid": true, "ever_ordered": true, "visible_now": true,
      "ordered": true, "phase": "post_order", "pid": getpid(),
      "window_number": controller.panel.windowNumber, "visible_windows": visibleWindows,
      "process_alive": processAlive, "pid_owned": pidOwned, "lock_owned": lockOwned, "descriptor_owned": descriptorOwned,
      "descriptor_checks": descriptorChecks,
      "front_bundle": focus.bundle, "expected_front_bundle": expectedFocus.bundle,
      "front_pid": focus.pid, "expected_front_pid": expectedFocus.pid,
      "front_window": focus.windowID, "expected_front_window": expectedFocus.windowID,
      "front_title": focus.windowTitle, "expected_front_title": expectedFocus.windowTitle,
      "front_bounds": rect(focus.windowBounds), "expected_front_bounds": rect(expectedFocus.windowBounds),
      "pointer": ["x": point.x, "y": point.y], "host": rect(controller.hostAnchor),
      "panel": rect(controller.panel.frame), "expected_panel": rect(expectedPanel),
      "observed_height": controller.panel.frame.height, "expected_height": expectedPanel.height, "display": rect(display),
    ]
    do {
      let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
      try data.write(to: URL(fileURLWithPath: stateReport), options: .atomic)
    } catch { controller.panel.orderOut(nil); NSApp.terminate(nil) }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    controller.exitHandler = { NSApp.terminate(nil) }
    signal(SIGTERM, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    source.setEventHandler { NSApp.terminate(nil) }
    source.resume()
    signalSource = source
    screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in NSApp.terminate(nil) }
    wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in NSApp.terminate(nil) }

    if stateReport != nil {
      let before = NSEvent.mouseLocation
      guard Self.shouldOrder(point: before, host: controller.hostAnchor) else {
        writeFailure("pre_order_pointer_moved", point: before, everOrdered: false)
        NSApp.terminate(nil)
        return
      }
      controller.show()
      let after = NSEvent.mouseLocation
      guard Self.shouldOrder(point: after, host: controller.hostAnchor) else {
        controller.panel.orderOut(nil)
        guard NSApp.windows.filter({ $0.isVisible }).isEmpty else { NSApp.terminate(nil); return }
        writeFailure("post_order_pointer_moved", point: after, everOrdered: true)
        NSApp.terminate(nil)
        return
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in self?.writeLaunchReport() }
    } else {
      controller.show()
    }
    timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.observePointer() }
  }

  private func observePointer() {
    if Self.shouldPauseDismissal(isKey: controller.panel.isKeyWindow, hasAccessibilityFocus: controller.hasFocusedAccessibilityDescendant()) {
      outsideSince = nil
      lastButtons = NSEvent.pressedMouseButtons
      let escape = CGEventSource.keyState(.combinedSessionState, key: 53)
      if escape && !lastEscape { NSApp.terminate(nil); return }
      lastEscape = escape
      return
    }
    let point = NSEvent.mouseLocation
    let insidePanel = controller.panel.frame.insetBy(dx: -2, dy: -2).contains(point)
    let insideHost = controller.hostAnchor.insetBy(dx: -2, dy: -2).contains(point)
    let inside = insidePanel || insideHost
    if inside {
      outsideSince = nil
    } else if let started = outsideSince {
      if Date().timeIntervalSince(started) >= 0.130 { NSApp.terminate(nil); return }
    } else {
      outsideSince = Date()
    }
    let buttons = NSEvent.pressedMouseButtons
    if buttons != lastButtons && buttons != 0 && !inside { NSApp.terminate(nil); return }
    lastButtons = buttons
    let escape = CGEventSource.keyState(.combinedSessionState, key: 53)
    if escape && !lastEscape { NSApp.terminate(nil); return }
    lastEscape = escape
  }

  // Explicit app deactivation (including opening an event action) closes the
  // accessory panel; only the pointer auto-dismiss timer uses the pause rule.
  func applicationDidResignActive(_ notification: Notification) { NSApp.terminate(nil) }
  func applicationWillTerminate(_ notification: Notification) {
    if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    controller.provider.cancel()
    clearPID()
  }
}

private final class ContenderTestApplication: NSObject, NSApplicationDelegate {
  let controller: CalendarPanelController
  let terminationSource: DispatchSourceSignal

  init(controller: CalendarPanelController) {
    self.controller = controller
    signal(SIGTERM, SIG_IGN)
    terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    super.init()
    terminationSource.setEventHandler { NSApp.terminate(nil) }
    terminationSource.resume()
  }

  func applicationWillTerminate(_ notification: Notification) {
    controller.provider.cancel()
    clearPID()
  }
}

@main
struct Main {
  static func main() throws {
    var arguments = Arguments()
    if arguments.usageInvalid { fputs("Usage: invalid calendar-panel arguments\n", stderr); exit(64) }
    if arguments.close { exit(closeOwnedAndWait() ? 0 : 1) }

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    if !arguments.anchorCG.isEmpty {
      switch ProductionAnchorResolver.resolve(arguments.anchorCG, pointer: NSEvent.mouseLocation) {
      case let .success(anchor, display, _):
        arguments.anchor = anchor
        arguments.display = display
      case .invalid:
        fputs("Calendar panel display anchor is invalid\n", stderr)
        exit(5)
      case .pointerMismatch:
        fputs("Calendar panel pointer left its exact bar anchor\n", stderr)
        exit(75)
      }
    }
    let expectedFocus = arguments.anchorCurrentPointer ? captureFrontFocus() : FrontFocus(pid: -1, bundle: "", windowID: -1, windowTitle: "", windowBounds: .zero)
    if arguments.anchorCurrentPointer {
      guard let report = arguments.stateReport else { fputs("State report is required for pointer anchoring\n", stderr); exit(5) }
      try? FileManager.default.removeItem(atPath: report)
      let point = NSEvent.mouseLocation
      guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else {
        let failure: [String: Any] = ["valid": false, "phase": "screen_failure", "ever_ordered": false,
                                      "visible_now": false, "visible_windows": 0,
                                      "pointer": ["x": point.x, "y": point.y]]
        let data = try! JSONSerialization.data(withJSONObject: failure, options: [.prettyPrinted, .sortedKeys])
        try! data.write(to: URL(fileURLWithPath: report), options: .atomic)
        exit(5)
      }
      let alignedPoint = CalendarPanelController.backingAlignedPoint(point, scale: screen.backingScaleFactor)
      guard let geometry = CalendarPanelController.pointerTestGeometry(point: alignedPoint, display: screen.frame),
            geometry.host.contains(point) else {
        let failure: [String: Any] = ["valid": false, "phase": "geometry_failure", "ever_ordered": false,
                                      "visible_now": false, "visible_windows": 0,
                                      "pointer": ["x": point.x, "y": point.y],
                                      "aligned_pointer": ["x": alignedPoint.x, "y": alignedPoint.y],
                                      "backing_scale": screen.backingScaleFactor]
        let data = try! JSONSerialization.data(withJSONObject: failure, options: [.prettyPrinted, .sortedKeys])
        try! data.write(to: URL(fileURLWithPath: report), options: .atomic)
        exit(5)
      }
      arguments.anchor = geometry.host
      arguments.display = screen.frame
    }
    if arguments.toggle {
      if lockedOwnerPID() != nil { exit(closeOwnedAndWait() ? 0 : 1) }
      if arguments.anchorCG.isEmpty && !arguments.holdTest {
        fputs("Bare toggle requires an existing verified owner or production anchors\n", stderr)
        exit(64)
      }
    }
    if arguments.selfTest { selfTest(); exit(0) }
    if arguments.holdTest {
      guard reserveSingleton() else { exit(0) }
      do { try writePID() } catch { clearPID(); exit(3) }
      signal(SIGTERM, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
      source.setEventHandler { clearPID(); exit(0) }
      source.resume()
      dispatchMain()
    }
    if let render = arguments.render {
      guard let fixture = arguments.fixture else {
        fputs("Fixture render requires an explicit offline fixture\n", stderr)
        exit(64)
      }
      let controller: CalendarPanelController
      do {
        controller = try CalendarPanelController(anchor: arguments.anchor, display: arguments.display, icalBuddy: arguments.icalBuddy, fixture: fixture, selected: arguments.selected, now: arguments.now)
      } catch {
        fputs("Calendar panel configuration failed\n", stderr)
        exit(2)
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.25))
      if arguments.scrollBottom { controller.scrollToBottom() }
      do {
        try controller.renderPNG(path: render)
        if let geometry = arguments.geometry {
          let data = try JSONSerialization.data(withJSONObject: controller.geometry(), options: [.prettyPrinted, .sortedKeys])
          try data.write(to: URL(fileURLWithPath: geometry), options: .atomic)
        }
      } catch {
        fputs("Fixture render failed: \(error)\n", stderr)
        exit(1)
      }
      exit(0)
    }

    // Every non-render production path owns the hardened singleton before a
    // controller can initialize its provider or launch an iCal query.
    guard reserveSingleton() else { exit(0) }
    do { try writePID() } catch { clearPID(); exit(3) }
    let controller: CalendarPanelController
    do {
      controller = try CalendarPanelController(anchor: arguments.anchor, display: arguments.display, icalBuddy: arguments.icalBuddy, fixture: nil, selected: arguments.selected, now: arguments.now)
    } catch {
      clearPID()
      fputs("Calendar panel configuration failed\n", stderr)
      exit(2)
    }
    if arguments.contenderTest {
      let delegate = ContenderTestApplication(controller: controller)
      app.delegate = delegate
      app.run()
      exit(0)
    }
    let delegate = PanelApplication(controller: controller, stateReport: arguments.anchorCurrentPointer ? arguments.stateReport : nil, expectedFocus: expectedFocus)
    app.delegate = delegate
    app.run()
  }
}
