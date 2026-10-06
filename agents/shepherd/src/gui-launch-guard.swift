// gui-launch-guard: the event-driven half of bin/gui-launch (its docstring is the user documentation).
//
// Guards a launch that gui-launch built (`open -g …` or an executable) and/or processes it attaches to. The
// tree, each member remembered with its start time and dropped when its pid turns out to name another process:
//   --exec: the spawned executable and its descendants (it also gets GUI_LAUNCH_TOKEN, for symmetry);
//   --open: each process whose environment carries GUI_LAUNCH_TOKEN=<this launch's random token>, which the
//     guard hands to `open --env`, and its descendants;
//   --attach-exe E --attach-argv N: each process whose executable's real path is E and one of whose arguments
//     contains N, and its descendants.
// Processes are adopted when they activate (before the restore decision), when an app launches, and by a scan
// of all processes every 150 ms (the token is read only from processes absent from the snapshot taken before
// the launch). Until the guard ends it
//   - reverts activations: when a tree process becomes frontmost, it focuses Tim's restore-target window by id
//     through yabai (the one he had focused at launch or after his last own app switch), or re-activates his
//     app when that window is gone or yabai fails;
//   - restores Tim's Space: when his display's visible Space changed after a tree activation, focusing that
//     window again brings it back;
//   - parks windows: each tree window that Accessibility reports created or focused, and each tree window
//     yabai lists when the tree activates or the active Space changes, is moved by id to --space.
// The guard ends after --guard-seconds; when the launched tree has exited (without attach flags); when
// --parent-pid (gui-launch) exits, even by SIGKILL; on SIGTERM/SIGINT; or (--open) when no token-bearing
// process appeared within --adopt-timeout. It never quits what it launched. Events go to stdout as JSON lines;
// the summary gui-launch checks goes to --summary.
// Threads: main handles workspace notifications and reverts, so a slow app never delays a revert; Accessibility
// calls run on axQueue (observer callbacks on their own run loop thread), window moves on yabaiQueue, Tim's
// restore target and Space on timQueue, the process scan on scanQueue. Every yabai call has a deadline.
//
// usage: gui-launch-guard --space N --guard-seconds S --yabai PATH --summary PATH [--parent-pid P]
//            [--adopt-timeout S] [--attach-exe E --attach-argv N] [(--exec | --open) -- <argv to spawn>]
//        gui-launch-guard --screens   screen name -> CGDirectDisplayID (yabai's display "id"), as JSON
//        gui-launch-guard --decide    tree, restore and Space decisions for synthetic processes on stdin (tests)
//        gui-launch-guard --resolve [--token T] [--attach-exe E --attach-argv N]
//                                     tree decisions for live processes named on stdin (tests)
// build: swiftc -O -swift-version 5 -target arm64-apple-macos13 \
//          -o ~/.local/bin/gui-launch-guard src/gui-launch-guard.swift
import AppKit
import ApplicationServices
import CryptoKit
import Security

// MARK: - Decisions (pure; --decide feeds them synthetic processes, activations and Spaces)

/// The Spaces Tim works on.
let timSpaces: Set<Int> = [1, 2, 3, 4]

func hasSubsequence(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
    guard !needle.isEmpty else { return true }
    guard haystack.count >= needle.count else { return false }
    for i in 0...(haystack.count - needle.count) where haystack[i] == needle[0] {
        if haystack[i..<(i + needle.count)].elementsEqual(needle) { return true }
    }
    return false
}

/// A process's arguments and environment, as KERN_PROCARGS2 reports them.
struct ProcArgs {
    var argv: [[UInt8]]
    var env: [[UInt8]]
}

/// KERN_PROCARGS2: argc (Int32), the exec path, NUL padding, argc NUL-terminated arguments, then the
/// environment's NUL-terminated entries, up to an empty one or the end.
func parseProcArgs(_ bytes: [UInt8]) -> ProcArgs? {
    guard bytes.count >= 4 else { return nil }
    let argc = Int(Int32(bitPattern: UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24))
    var i = 4
    func next() -> [UInt8]? {
        guard i < bytes.count else { return nil }
        let start = i
        while i < bytes.count && bytes[i] != 0 { i += 1 }
        defer { i += 1 }
        return Array(bytes[start..<i])
    }
    guard argc >= 0, next() != nil else { return nil }
    while i < bytes.count && bytes[i] == 0 { i += 1 }
    var argv: [[UInt8]] = []
    while argv.count < argc, let arg = next() { argv.append(arg) }
    guard argv.count == argc else { return nil }
    var env: [[UInt8]] = []
    while let entry = next(), !entry.isEmpty { env.append(entry) }
    return ProcArgs(argv: argv, env: env)
}

/// --attach-exe/--attach-argv: the executable's real path is `exe` and one argument contains `needle`.
/// Names and bundle ids play no part.
struct AttachMatcher {
    let exe: String
    let needle: [UInt8]

    func matches(exe path: String?, argv: [[UInt8]]) -> Bool {
        path == exe && argv.contains { hasSubsequence($0, needle) }
    }
}

/// What the tree rules read about processes: live (proc_pidinfo, proc_pidpath, KERN_PROCARGS2) or synthetic.
struct ProcSource {
    var parent: (pid_t) -> pid_t
    /// When the process started, in µs since the epoch; nil: no such process.
    var start: (pid_t) -> UInt64?
    /// The real path of its executable.
    var exe: (pid_t) -> String?
    /// nil: unreadable (another user's process) or gone.
    var args: (pid_t) -> ProcArgs?
    /// Absent from the snapshot taken before the launch.
    var isNew: (pid_t) -> Bool
}

/// The tree: roots (the spawned executable, token-bearing processes), attached processes (the attach matcher)
/// and the processes below them, each remembered with its start time, so a pid that comes to name another
/// process is dropped instead of trusted.
struct Lineage {
    enum Rule: String { case exec, launchToken = "launch-token", exeArgv = "exe-argv" }
    struct Adoption: Equatable {
        let pid: pid_t
        let rule: Rule
    }
    struct Resolution {
        var inTree = false
        var adopted: Adoption?
        var dropped: [pid_t] = []
    }

    /// `GUI_LAUNCH_TOKEN=<token>` (--open).
    let tokenEntry: [UInt8]?
    let matcher: AttachMatcher?
    private(set) var members: [pid_t: UInt64] = [:]
    private(set) var roots = Set<pid_t>()
    private(set) var attached = Set<pid_t>()

    init(tokenEntry: [UInt8]?, matcher: AttachMatcher?) {
        self.tokenEntry = tokenEntry
        self.matcher = matcher
    }

    mutating func addRoot(_ pid: pid_t, start: UInt64) {
        members[pid] = start
        roots.insert(pid)
    }

    /// The rule that adopts `pid` on its own. The match and the start time are read in one pass: a process that
    /// changed while its arguments were read is not adopted.
    func rule(for pid: pid_t, start: UInt64, _ source: ProcSource) -> Rule? {
        let byToken = tokenEntry != nil && source.isNew(pid)
        let byExe = matcher != nil && source.exe(pid) == matcher?.exe
        guard byToken || byExe, let args = source.args(pid), source.start(pid) == start else { return nil }
        if byToken, let tokenEntry, args.env.contains(tokenEntry) { return .launchToken }
        if byExe, let matcher, matcher.matches(exe: source.exe(pid), argv: args.argv) { return .exeArgv }
        return nil
    }

    /// Whether `pid` is in the tree. It, then each ancestor up to launchd, is checked: a member whose start time
    /// still matches (one that does not is dropped: its pid was reused) or, when `adopting`, a process that a
    /// rule adopts puts every process checked so far in the tree, with its start time. `ancestors: false`
    /// checks `pid` alone (the scan reaches every process anyway).
    mutating func resolve(_ pid: pid_t, adopting: Bool, ancestors: Bool = true, _ source: ProcSource) -> Resolution {
        var result = Resolution()
        var chain: [(pid: pid_t, start: UInt64)] = []
        var p = pid
        while p > 1 && chain.count < 64 {
            guard let start = source.start(p) else { break }
            if let known = members[p] {
                if known == start {
                    join(chain)
                    result.inTree = true
                    return result
                }
                drop(p)
                result.dropped.append(p)
            }
            chain.append((p, start))
            if adopting, let rule = rule(for: p, start: start, source) {
                join(chain)
                if rule == .exeArgv { attached.insert(p) } else { roots.insert(p) }
                result.inTree = true
                result.adopted = Adoption(pid: p, rule: rule)
                return result
            }
            guard ancestors else { break }
            p = source.parent(p)
        }
        return result
    }

    private mutating func join(_ chain: [(pid: pid_t, start: UInt64)]) {
        for (pid, start) in chain { members[pid] = start }
    }

    private mutating func drop(_ pid: pid_t) {
        members[pid] = nil
        roots.remove(pid)
        attached.remove(pid)
    }

    func anyAlive(_ source: ProcSource) -> Bool { members.contains { source.start($0.key) == $0.value } }
}

/// What to do when an app becomes frontmost. `userFront` is the app to give focus back to: the frontmost app
/// at launch, then whichever app outside the tree last became frontmost (the user's choice).
struct RestorePolicy {
    enum Decision: Equatable {
        case restore(to: pid_t)            // a tree process took focus: give it back
        case restored(latency: Double)     // the user's app is frontmost again; seconds since the theft
        case user                          // an app outside the tree: the user's new choice
        case unrestorable                  // a tree process took focus and there is no app to give it back to
        case afterGuard
    }

    var userFront: pid_t?
    let guardUntil: Double
    /// When the tree took focus that is not yet given back.
    private(set) var pendingSince: Double?

    init(userFront: pid_t?, guardUntil: Double) {
        self.userFront = userFront
        self.guardUntil = guardUntil
    }

    mutating func activation(pid: pid_t, inTree: Bool, at t: Double) -> Decision {
        if t > guardUntil { return .afterGuard }
        if inTree {
            guard let to = userFront else { return .unrestorable }
            if pendingSince == nil { pendingSince = t }
            return .restore(to: to)
        }
        if pid == userFront, let since = pendingSince {
            pendingSince = nil
            return .restored(latency: t - since)
        }
        userFront = pid
        pendingSince = nil
        return .user
    }
}

/// The window a revert focuses: Tim's focused window at launch, then, after each of his own app switches, the
/// window yabai reports focused once it belongs to the app he switched to. A tree activation never changes it,
/// and a report of a tree window, or of the app he left (yabai lagging), is not taken.
struct RestoreTarget: Equatable {
    private(set) var pid: pid_t?
    private(set) var window: Int?

    init(pid: pid_t?) { self.pid = pid }

    /// The window to focus to give focus back to `app`, if it is the target's.
    func window(for app: pid_t) -> Int? { app == pid ? window : nil }

    /// Tim activated `app`, outside the tree: its window is not known yet.
    mutating func userSwitched(to app: pid_t) {
        pid = app
        window = nil
    }

    /// yabai reports window `id` of `owner` focused; returns whether it became the target.
    mutating func focused(_ id: Int, owner: pid_t, ownerInTree: Bool) -> Bool {
        guard !ownerInTree, owner == pid else { return false }
        window = id
        return true
    }
}

/// The Space Tim's display should show. A change there to a Space that is not one of his, within `grace` of a
/// tree activation, is the tree's doing, and so is staying on that Space: restore it by focusing his
/// restore-target window, if that window is on the Space he was on. Any other change is his own and becomes
/// the expected Space.
struct SpacePolicy {
    enum Decision: Equatable {
        case unchanged
        case user(Int)
        case restore(from: Int, to: Int, window: Int)
        case unrestorable(from: Int, to: Int)
    }

    static let grace = 2.0
    private(set) var expected: Int?
    private(set) var theftAt: Double?
    /// The Space the tree moved Tim's display to, while it still shows it.
    private(set) var thiefSpace: Int?

    init(expected: Int?) { self.expected = expected }

    mutating func theft(at t: Double) { theftAt = t }

    func inGrace(at t: Double) -> Bool { theftAt.map { t - $0 <= SpacePolicy.grace } ?? false }

    /// Tim's display shows `visible` at `t`; `window` is his restore target and `windowSpace` the Space it is on
    /// (nil: gone).
    mutating func observed(_ visible: Int, at t: Double, window: Int?, windowSpace: Int?) -> Decision {
        guard let want = expected else { return .unchanged }
        if visible == want {
            thiefSpace = nil
            return .unchanged
        }
        if visible == thiefSpace || (inGrace(at: t) && !timSpaces.contains(visible)) {
            thiefSpace = visible
            guard let window, windowSpace == want else { return .unrestorable(from: visible, to: want) }
            return .restore(from: visible, to: want, window: window)
        }
        expected = visible
        thiefSpace = nil
        return .user(visible)
    }
}

// MARK: - Output

signal(SIGPIPE, SIG_IGN)
let outLock = NSLock()
let isoFormat: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

func iso(_ date: Date = Date()) -> String { isoFormat.string(from: date) }
func uptime() -> Double { ProcessInfo.processInfo.systemUptime }
/// A duration for JSON, to `places` decimals (a Double would print as 4.3369999999999997).
func decimal(_ value: Double, _ places: Int) -> NSDecimalNumber { NSDecimalNumber(string: String(format: "%.\(places)f", value)) }
func ms(_ seconds: Double) -> NSDecimalNumber { decimal(seconds * 1000, 1) }

func writeLine(_ object: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
    data.append(10)
    outLock.lock()
    data.withUnsafeBytes { _ = write(1, $0.baseAddress, $0.count) }
    outLock.unlock()
}

func emit(_ event: [String: Any]) {
    var record = event
    if record["at"] == nil { record["at"] = iso() }
    writeLine(record)
}

func complain(_ message: String) {
    FileHandle.standardError.write(("gui-launch-guard: " + message + "\n").data(using: .utf8)!)
}

func fail(_ message: String) -> Never {
    emit(["event": "error", "message": message])
    complain(message)
    exit(2)
}

func describe(_ app: NSRunningApplication?) -> Any {
    guard let app else { return NSNull() }
    return ["pid": Int(app.processIdentifier), "name": app.localizedName ?? "", "bundle": app.bundleIdentifier ?? ""]
}

/// The token in events: it is not secret, only noise, so it appears as a short hash.
func shortHash(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined().prefix(12).description
}

func tokenEntry(_ token: String) -> [UInt8] { Array("GUI_LAUNCH_TOKEN=\(token)".utf8) }

final class Locked<Value> {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func update<Result>(_ change: (inout Value) -> Result) -> Result {
        lock.lock(); defer { lock.unlock() }
        return change(&stored)
    }
}

// MARK: - Live process facts

func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return info
}

func processStart(_ pid: pid_t) -> UInt64? {
    bsdInfo(pid).map { $0.pbi_start_tvsec &* 1_000_000 &+ $0.pbi_start_tvusec }
}

func parentPid(_ pid: pid_t) -> pid_t { bsdInfo(pid).map { pid_t(bitPattern: $0.pbi_ppid) } ?? 0 }

/// How the scan last saw a process: its start time and name. A change of either (pid reuse, exec) has it read
/// again; anything else needs one cheap proc_pidinfo per scan instead of a path and argument read.
struct Sighting: Equatable {
    let start: UInt64
    let name: (UInt64, UInt64)

    init(_ info: proc_bsdinfo) {
        start = info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec
        var comm = info.pbi_comm
        name = withUnsafeBytes(of: &comm) { ($0.loadUnaligned(fromByteOffset: 0, as: UInt64.self), $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self)) }
    }

    static func == (a: Sighting, b: Sighting) -> Bool { a.start == b.start && a.name == b.name }
}

func procPath(_ pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    return proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : nil
}

func realPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}

func procArgs(_ pid: pid_t) -> ProcArgs? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
    return parseProcArgs(Array(buffer[..<size]))
}

func allPids() -> [pid_t] {
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return [] }
    var buffer = [pid_t](repeating: 0, count: Int(count) + 64)
    let got = proc_listallpids(&buffer, Int32(buffer.count * MemoryLayout<pid_t>.stride))
    return got > 0 ? buffer[..<Int(got)].filter { $0 > 0 } : []
}

/// The live tree: Lineage on live process facts behind a lock, reporting adoptions and drops as events.
final class Tree {
    private let lock = NSLock()
    private var lineage: Lineage
    private var snapshot: Set<pid_t>
    private var realPaths: [String: String] = [:]
    /// The scan's: processes checked and not adopted.
    private var checked: [pid_t: Sighting] = [:]
    private var adoptions: [[String: Any]] = []
    private var drops: [[String: Any]] = []
    private let t0: Double
    private let tokenHash: String?
    private let needle: String?

    init(_ lineage: Lineage, snapshot: Set<pid_t>, t0: Double, tokenHash: String?, needle: String?) {
        self.lineage = lineage
        self.snapshot = snapshot
        self.t0 = t0
        self.tokenHash = tokenHash
        self.needle = needle
    }

    private func exe(_ pid: pid_t) -> String? {  // lock held
        guard let raw = procPath(pid) else { return nil }
        if let known = realPaths[raw] { return known }
        let real = realPath(raw) ?? raw
        realPaths[raw] = real
        return real
    }

    private var source: ProcSource {  // used with the lock held
        ProcSource(parent: parentPid, start: processStart, exe: { self.exe($0) }, args: procArgs,
                   isNew: { !self.snapshot.contains($0) })
    }

    func addRoot(_ pid: pid_t) {
        lock.lock(); defer { lock.unlock() }
        lineage.addRoot(pid, start: processStart(pid) ?? 0)
    }

    /// Membership only, as before a window move: never adopts.
    func contains(_ pid: pid_t) -> Bool { resolve(pid, via: nil) }

    /// An adoption point (an activation, an app launch): pid is in the tree, or it or an ancestor is adopted.
    func adopt(_ pid: pid_t, via: String) -> Bool { resolve(pid, via: via) }

    private func resolve(_ pid: pid_t, via: String?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let result = lineage.resolve(pid, adopting: via != nil, source)
        report(result, via: via ?? "")
        return result.inTree
    }

    private func report(_ result: Lineage.Resolution, via: String) {  // lock held
        for pid in result.dropped {
            let record: [String: Any] = ["event": "dropped", "pid": Int(pid), "reason": "pid reused"]
            drops.append(record)
            emit(record)
        }
        guard let adoption = result.adopted else { return }
        var record: [String: Any] = ["event": "attached", "pid": Int(adoption.pid), "via": via, "rule": adoption.rule.rawValue,
                                     "ms_since_start": ms(uptime() - t0)]
        if adoption.rule == .launchToken { record["token"] = tokenHash }
        if adoption.rule == .exeArgv {
            record["exe"] = lineage.matcher?.exe
            record["needle"] = needle
        }
        adoptions.append(record)
        emit(record)
    }

    /// The periodic scan: every process outside the tree that a rule could adopt on its own (the token rule
    /// reads only processes absent from the pre-launch snapshot, the attach rule only those running
    /// --attach-exe). A process checked and not adopted is skipped until its Sighting changes. Returns the
    /// pids adopted.
    func scan() -> [pid_t] {
        let pids = allPids()
        lock.lock(); defer { lock.unlock() }
        let live = Set(pids)
        snapshot.formIntersection(live)  // a pid that went away and came back names a new process
        checked = checked.filter { live.contains($0.key) }
        let me = getpid()
        var adopted: [pid_t] = []
        for pid in pids where pid != me && lineage.members[pid] == nil {
            guard lineage.matcher != nil || !snapshot.contains(pid), let info = bsdInfo(pid) else { continue }
            let sighting = Sighting(info)
            if checked[pid] == sighting { continue }
            let result = lineage.resolve(pid, adopting: true, ancestors: false, source)
            report(result, via: "scan")
            if let adoption = result.adopted { adopted.append(adoption.pid) } else { checked[pid] = sighting }
        }
        return adopted
    }

    var hasRoots: Bool {
        lock.lock(); defer { lock.unlock() }
        return !lineage.roots.isEmpty
    }

    var anyAlive: Bool {
        lock.lock(); defer { lock.unlock() }
        return lineage.anyAlive(source)
    }

    var summary: [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["roots": lineage.roots.sorted().map(Int.init), "tree": lineage.members.keys.sorted().map(Int.init),
                "attached": adoptions, "dropped": drops]
    }
}

// MARK: - Modes that launch nothing

func screens() -> Never {
    var names: [String: Int] = [:]
    for screen in NSScreen.screens {
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            names[screen.localizedName] = number.intValue
        }
    }
    let data = try! JSONSerialization.data(withJSONObject: names, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
    exit(0)
}

/// stdin: a header `{"front": pid|null, "frontWindow": id|null, "guardSeconds": S, "token": T, "attach": {"exe",
/// "needle"}, "before": [pid], "roots": [pid], "timSpace": n, "procs": [...]}` (all but front and guardSeconds
/// optional), then rows. A row's `procs`, `[{"pid", "ppid", "start", "exe", "argv", "env"}]`, defines synthetic
/// processes (replacing any with the same pid; "start": null means gone, absent means 1); its action is one of
/// `{"t", "activate": pid, "focused": {"id", "pid"}}` (an activation; `focused` is the window yabai reports
/// focused afterwards, optional), `{"t", "launch": pid}` (an app launch or a scan sighting), `{"t", "move": pid}`
/// (the check before a window move), `{"t", "space": n, "windowSpace": n|null}` (the Space Tim's display shows,
/// and the one his restore-target window is on). stdout: one line per action.
func decide() -> Never {
    var procs: [pid_t: [String: Any]] = [:]
    var before = Set<pid_t>()
    func number(_ value: Any?) -> NSNumber? { value as? NSNumber }
    func pid(_ value: Any?) -> pid_t? { number(value).map { pid_t($0.int32Value) } }
    func strings(_ value: Any?) -> [[UInt8]] { (value as? [String] ?? []).map { Array($0.utf8) } }
    func define(_ rows: Any?) {
        for row in rows as? [[String: Any]] ?? [] { if let p = pid(row["pid"]) { procs[p] = row } }
    }
    let source = ProcSource(
        parent: { pid(procs[$0]?["ppid"]) ?? 1 },
        start: { p in
            guard let row = procs[p] else { return nil }
            if row["start"] is NSNull { return nil }
            return number(row["start"])?.uint64Value ?? 1
        },
        exe: { procs[$0]?["exe"] as? String },
        args: { p in procs[p].map { ProcArgs(argv: strings($0["argv"]), env: strings($0["env"])) } },
        isNew: { !before.contains($0) })
    var policy = RestorePolicy(userFront: nil, guardUntil: 0)
    var lineage = Lineage(tokenEntry: nil, matcher: nil)
    var target = RestoreTarget(pid: nil)
    var spaces = SpacePolicy(expected: nil)
    var started = false
    while let line = readLine() {
        guard !line.isEmpty, let data = line.data(using: .utf8),
              let row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
        define(row["procs"])
        if !started {
            started = true
            let front = pid(row["front"])
            policy = RestorePolicy(userFront: front, guardUntil: number(row["guardSeconds"])?.doubleValue ?? 0)
            let attach = row["attach"] as? [String: Any]
            lineage = Lineage(tokenEntry: (row["token"] as? String).map(tokenEntry),
                              matcher: attach.map { AttachMatcher(exe: $0["exe"] as? String ?? "", needle: Array(($0["needle"] as? String ?? "").utf8)) })
            before = Set((row["before"] as? [NSNumber] ?? []).map { pid_t($0.int32Value) })
            for root in (row["roots"] as? [NSNumber] ?? []).map({ pid_t($0.int32Value) }) {
                lineage.addRoot(root, start: source.start(root) ?? 1)
            }
            target = RestoreTarget(pid: front)
            if let front, let window = number(row["frontWindow"])?.intValue { _ = target.focused(window, owner: front, ownerInTree: false) }
            spaces = SpacePolicy(expected: number(row["timSpace"])?.intValue)
            continue
        }
        let t = number(row["t"])?.doubleValue ?? 0
        var out: [String: Any] = ["t": t]
        func record(_ result: Lineage.Resolution) {
            out["tree"] = result.inTree
            if let adoption = result.adopted { out["attached"] = ["pid": Int(adoption.pid), "rule": adoption.rule.rawValue] as [String: Any] }
            if !result.dropped.isEmpty { out["dropped"] = result.dropped.map(Int.init) }
        }
        if let p = pid(row["activate"]) {
            out["pid"] = Int(p)
            let result = lineage.resolve(p, adopting: true, source)
            record(result)
            switch policy.activation(pid: p, inTree: result.inTree, at: t) {
            case .restore(let to):
                out["decision"] = "restore"
                out["to"] = Int(to)
                out["window"] = target.window(for: to) ?? NSNull()
                spaces.theft(at: t)
            case .restored(let latency): out["decision"] = "restored"; out["latencyMs"] = ms(latency)
            case .user: out["decision"] = "user"; target.userSwitched(to: p)
            case .unrestorable: out["decision"] = "unrestorable"; spaces.theft(at: t)
            case .afterGuard: out["decision"] = "after-guard"
            }
            if let focused = row["focused"] as? [String: Any], let id = number(focused["id"])?.intValue, let owner = pid(focused["pid"]) {
                _ = target.focused(id, owner: owner, ownerInTree: lineage.resolve(owner, adopting: false, source).inTree)
            }
            out["target"] = target.window ?? NSNull()
        } else if let p = pid(row["launch"]) {
            out["pid"] = Int(p)
            record(lineage.resolve(p, adopting: true, source))
        } else if let p = pid(row["move"]) {
            out["pid"] = Int(p)
            record(lineage.resolve(p, adopting: false, source))
        } else if let visible = number(row["space"])?.intValue {
            switch spaces.observed(visible, at: t, window: target.window, windowSpace: number(row["windowSpace"])?.intValue) {
            case .unchanged: out["space"] = "unchanged"
            case .user(let space): out["space"] = "user"; out["expected"] = space
            case .restore(let from, let to, let window): out["space"] = "restore"; out["from"] = from; out["to"] = to; out["window"] = window
            case .unrestorable(let from, let to): out["space"] = "unrestorable"; out["from"] = from; out["to"] = to
            }
        } else {
            continue
        }
        writeLine(out)
    }
    exit(0)
}

/// stdin lines: `scan` (one periodic scan), `<pid>` (an activation's tree decision: adopts), `move <pid>`
/// (membership only). stdout: `{"ready": true}` once the pre-launch snapshot is taken, then the attached and
/// dropped events, and `{"scanned": [pid]}` or `{"pid", "tree"}` per line.
func resolveLive(token: String?, matcher: AttachMatcher?, needle: String?) -> Never {
    let tree = Tree(Lineage(tokenEntry: token.map(tokenEntry), matcher: matcher), snapshot: Set(allPids()), t0: uptime(),
                    tokenHash: token.map(shortHash), needle: needle)
    writeLine(["ready": true])
    while let line = readLine() {
        let words = line.split(separator: " ").map(String.init)
        if words == ["scan"] {
            writeLine(["scanned": tree.scan().map(Int.init)])
        } else if words.count == 2, words[0] == "move", let p = pid_t(words[1]) {
            writeLine(["pid": Int(p), "tree": tree.contains(p)])
        } else if words.count == 1, let p = pid_t(words[0]) {
            writeLine(["pid": Int(p), "tree": tree.adopt(p, via: "activation")])
        }
    }
    exit(0)
}

// MARK: - Arguments

var argv = Array(CommandLine.arguments.dropFirst())
if argv.first == "--screens" { screens() }
if argv.first == "--decide" { decide() }

var space = 0, guardSeconds = 60.0, adoptTimeout = 30.0
var yabaiPath = "", summaryPath = ""
var mode: String?  // "exec" or "open"
var resolving = false
var parentWatch: pid_t?
var attachExe: String?, attachNeedle: String?, givenToken: String?
var launchArgv: [String] = []
while !argv.isEmpty {
    let flag = argv.removeFirst()
    if flag == "--" { launchArgv = argv; break }
    if flag == "--exec" || flag == "--open" { mode = String(flag.dropFirst(2)); continue }
    if flag == "--resolve" { resolving = true; continue }
    guard !argv.isEmpty else { fail("\(flag) needs a value") }
    let value = argv.removeFirst()
    switch flag {
    case "--space": space = Int(value) ?? 0
    case "--guard-seconds": guardSeconds = Double(value) ?? -1
    case "--adopt-timeout": adoptTimeout = Double(value) ?? -1
    case "--yabai": yabaiPath = value
    case "--summary": summaryPath = value
    case "--parent-pid": parentWatch = pid_t(value) ?? -1
    case "--attach-exe": attachExe = value
    case "--attach-argv": attachNeedle = value
    case "--token": givenToken = value
    default: fail("unknown flag \(flag)")
    }
}
if (attachExe == nil) != (attachNeedle == nil) { fail("--attach-exe and --attach-argv go together") }
var matcher: AttachMatcher?
if let attachExe, let attachNeedle {
    guard !attachNeedle.isEmpty else { fail("--attach-argv needs a non-empty needle") }
    guard let exe = realPath(attachExe) else { fail("no executable at \(attachExe)") }
    matcher = AttachMatcher(exe: exe, needle: Array(attachNeedle.utf8))
}
if resolving { resolveLive(token: givenToken, matcher: matcher, needle: attachNeedle) }
guard givenToken == nil else { fail("--token is for --resolve; a launch makes its own") }
guard space > 0, guardSeconds > 0, guardSeconds.isFinite, adoptTimeout > 0, adoptTimeout.isFinite,
      !yabaiPath.isEmpty, !summaryPath.isEmpty, (mode == nil) == launchArgv.isEmpty, mode != nil || matcher != nil else {
    fail("usage: --space N --guard-seconds S --yabai PATH --summary PATH [--parent-pid P] [--adopt-timeout S] " +
         "[--attach-exe E --attach-argv N] [(--exec | --open) -- argv]")
}
if mode == "open" && launchArgv.first != "/usr/bin/open" { fail("--open launches /usr/bin/open, not \(launchArgv[0])") }
if let parentWatch, parentWatch <= 1 || processStart(parentWatch) == nil { fail("--parent-pid \(parentWatch) names no process") }
// Parking windows needs Accessibility events; without them a window could sit on Tim's Space unseen.
guard AXIsProcessTrusted() else {
    fail("this process is not trusted for Accessibility, so it cannot see new windows: run it from a terminal app " +
         "listed in System Settings > Privacy & Security > Accessibility")
}
// macOS reports activations only to a process in a GUI session: in launchd's Background session the guard
// would see no theft and revert none.
var sessionID = SecuritySessionId(0)
var sessionBits = SessionAttributeBits(rawValue: 0)
guard SessionGetInfo(callerSecuritySession, &sessionID, &sessionBits) == errSecSuccess,
      sessionBits.contains(.sessionHasGraphicAccess) else {
    fail("this process is not in a GUI session, where activations are reported: start it through gui-launch")
}

// MARK: - State

let t0 = uptime()
let workspace = NSWorkspace.shared
let frontAtLaunch = workspace.frontmostApplication
let attaching = matcher != nil
let token = UUID().uuidString.lowercased()
let tokenHash = shortHash(token)
let tree = Tree(Lineage(tokenEntry: mode == "open" ? tokenEntry(token) : nil, matcher: matcher), snapshot: Set(allPids()),
                t0: t0, tokenHash: tokenHash, needle: attachNeedle)
var policy = RestorePolicy(userFront: frontAtLaunch?.processIdentifier, guardUntil: guardSeconds)
var theft: [String: Any]?          // the tree activation not yet given back (main thread)
var reverted: [[String: Any]] = []  // main thread
var lastRestore: (method: String, window: Int?) = ("", nil)  // main thread
var finished = false
let stopping = Locked(false)
var launchFailure: String?
var launchedAt: Double?
/// Problems the check must report: yabai calls that ran out of time.
let problems = Locked([String]())

let yabaiQueue = DispatchQueue(label: "gui-launch.yabai")
let axQueue = DispatchQueue(label: "gui-launch.ax")
let timQueue = DispatchQueue(label: "gui-launch.tim")
let scanQueue = DispatchQueue(label: "gui-launch.scan")

// MARK: - yabai (every call bounded)

final class Box<Value>: @unchecked Sendable {  // written by one reader thread, read after it signals
    var value: Value
    init(_ value: Value) { self.value = value }
}

/// One yabai call. One that does not finish within `timeout` is killed and recorded as a problem for the
/// check, never waited on.
@Sendable func yabai(_ args: [String], timeout: Double = 2) -> Any? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: yabaiPath)
    process.arguments = ["-m"] + args
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    do { try process.run() } catch { return nil }
    let output = Box(Data())
    let read = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        output.value = out.fileHandleForReading.readDataToEndOfFile()
        read.signal()
    }
    guard exited.wait(timeout: .now() + timeout) == .success else {
        process.terminate()
        let message = "yabai -m \(args.joined(separator: " ")) did not answer within \(timeout) s"
        problems.update { $0.append(message) }
        emit(["event": "yabai-timeout", "args": args, "timeoutS": timeout])
        return nil
    }
    read.wait()
    guard process.terminationStatus == 0 else { return nil }
    return output.value.isEmpty ? [:] as [String: Any] : try? JSONSerialization.jsonObject(with: output.value)
}

@Sendable func windowInfo(_ id: Int, timeout: Double = 2) -> [String: Any]? {
    yabai(["query", "--windows", "--window", String(id)], timeout: timeout) as? [String: Any]
}

/// yabai's focused window (a query; yabai acts on a window only when given its id) and AppKit's main screen.
@Sendable func focusContext() -> [String: Any] {
    let w = yabai(["query", "--windows", "--window"]) as? [String: Any]
    return ["window": w?["id"] ?? NSNull(), "windowPid": w?["pid"] ?? NSNull(), "windowApp": w?["app"] ?? NSNull(),
            "mainScreen": NSScreen.main?.localizedName ?? NSNull()]
}

/// The Space shown on Tim's display (the one holding Space 1).
@Sendable func timDisplaySpace() -> Int? {
    guard let spaces = yabai(["query", "--spaces"]) as? [[String: Any]],
          let display = spaces.first(where: { ($0["index"] as? NSNumber)?.intValue == 1 })?["display"] as? NSNumber else { return nil }
    let shown = spaces.first { ($0["display"] as? NSNumber) == display && $0["is-visible"] as? Bool == true }
    return (shown?["index"] as? NSNumber)?.intValue
}

/// Where focus sat at launch, for gui-launch's check: yabai's focused window, and the screen AppKit calls main
/// (the key window's); the Space Tim's display showed; and the window a revert focuses, if it is his front app's.
let focusAtLaunch = focusContext()
let timSpaceAtLaunch = timDisplaySpace()
let restoreTarget = Locked(RestoreTarget(pid: frontAtLaunch?.processIdentifier))
if let id = (focusAtLaunch["window"] as? NSNumber)?.intValue, let owner = (focusAtLaunch["windowPid"] as? NSNumber)?.int32Value {
    _ = restoreTarget.update { $0.focused(id, owner: owner, ownerInTree: false) }
}
let spacePolicy = Locked(SpacePolicy(expected: timSpaceAtLaunch))
let spaceEvents = Locked([[String: Any]]())

// MARK: - Windows (yabaiQueue; the final sweep on main)

let moves = Locked([[String: Any]]())

/// Moves one tree window to the target Space by id, after checking yabai knows it and that it is the tree's (its
/// pid, with the start time the tree recorded). `seen` is when the event that reported it arrived; yabai may
/// learn of a brand-new window a few ms after Accessibility does, so an unknown id is retried for up to a
/// second, without holding up the queue.
func park(_ id: Int, seen: Double, via: String, final: Bool = false) {
    guard final || !stopping.value else { return }
    guard let w = windowInfo(id) else {
        if !final && uptime() - seen < 1 { yabaiQueue.asyncAfter(deadline: .now() + 0.01) { park(id, seen: seen, via: via) } }
        return
    }
    guard let pid = (w["pid"] as? NSNumber)?.int32Value, let from = (w["space"] as? NSNumber)?.intValue, from != 0, from != space,
          tree.contains(pid) else { return }
    _ = yabai(["window", String(id), "--space", String(space)])
    let after = (windowInfo(id)?["space"] as? NSNumber)?.intValue
    let done = uptime()
    var record: [String: Any] = [
        "event": "window", "id": id, "pid": Int(pid), "app": w["app"] ?? "", "title": w["title"] ?? "",
        "subrole": w["subrole"] ?? "", "from": from, "to": after ?? NSNull(), "moved": after == space, "via": via,
        "latencyMs": ms(done - seen),
    ]
    if timSpaces.contains(from) { record["onTimSpaceMs"] = ms(done - seen) }
    moves.update { $0.append(record) }
    emit(record)
}

func sweep(_ via: String, final: Bool = false) {
    guard final || !stopping.value else { return }
    let seen = uptime()
    guard let windows = yabai(["query", "--windows"]) as? [[String: Any]] else { return }
    for w in windows {
        guard let id = (w["id"] as? NSNumber)?.intValue, let pid = (w["pid"] as? NSNumber)?.int32Value,
              let at = (w["space"] as? NSNumber)?.intValue, at != 0, at != space, tree.contains(pid) else { continue }
        park(id, seen: seen, via: via, final: final)
    }
}

// MARK: - Accessibility (axQueue; callbacks on axLoop's thread)

@_silgen_name("_AXUIElementGetWindow")
func axWindowID(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

var axLoop: CFRunLoop!
var observers: [pid_t: AXObserver] = [:]  // axQueue
let axReady = DispatchSemaphore(value: 0)
Thread {
    axLoop = CFRunLoopGetCurrent()
    let keepAlive = CFRunLoopTimerCreateWithHandler(nil, .greatestFiniteMagnitude, 0, 0, 0) { _ in }
    CFRunLoopAddTimer(axLoop, keepAlive, .defaultMode)
    axReady.signal()
    CFRunLoopRun()
}.start()
axReady.wait()

let axCallback: AXObserverCallback = { _, element, notification, _ in
    let seen = uptime()
    var id: CGWindowID = 0
    guard axWindowID(element, &id) == .success, id != 0 else { return }
    let via = notification as String == kAXWindowCreatedNotification ? "ax-created" : "ax-focused"
    yabaiQueue.async { park(Int(id), seen: seen, via: via) }
}

/// Subscribes to a tree process's window events. A just-launched app answers Accessibility only once its run
/// loop is up, so a refused subscription is retried, every 20 ms for the first 5 s (an adopted client may take
/// that long to become an app), then every 250 ms, until the guard ends.
func observe(_ pid: pid_t, attempt: Int = 0) {
    axQueue.async {
        guard observers[pid] == nil, processStart(pid) != nil, !stopping.value else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var created: AXObserver?
        guard AXObserverCreate(pid, axCallback, &created) == .success, let observer = created,
              AXObserverAddNotification(observer, app, kAXWindowCreatedNotification as CFString, nil) == .success else {
            axQueue.asyncAfter(deadline: .now() + (attempt < 250 ? 0.02 : 0.25)) { observe(pid, attempt: attempt + 1) }
            return
        }
        AXObserverAddNotification(observer, app, kAXFocusedWindowChangedNotification as CFString, nil)
        CFRunLoopAddSource(axLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
        CFRunLoopWakeUp(axLoop)
        observers[pid] = observer
        emit(["event": "observing", "pid": Int(pid)])
        // Windows opened before the subscription.
        var value: CFTypeRef?
        let seen = uptime()
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
           let windows = value as? [AXUIElement] {
            for window in windows {
                var id: CGWindowID = 0
                if axWindowID(window, &id) == .success, id != 0 { yabaiQueue.async { park(Int(id), seen: seen, via: "ax-existing") } }
            }
        }
    }
}

// MARK: - Tim's focus and Space

/// Gives focus back to Tim's app `pid`: by focusing his restore-target window through yabai (SkyLight acts at
/// once, and the window's Space comes back with it) once yabai confirms the window is still that app's, else by
/// re-activating the app (cooperative on macOS 14+: a slow app answers late). Main thread.
@Sendable func restoreFocus(to pid: pid_t) -> (ok: Bool, method: String, window: Int?) {
    if let window = restoreTarget.value.window(for: pid), let info = windowInfo(window, timeout: 0.5),
       (info["pid"] as? NSNumber)?.int32Value == pid, info["is-minimized"] as? Bool != true,
       yabai(["window", "--focus", String(window)], timeout: 0.5) != nil {
        return (true, "window", window)
    }
    guard let app = NSRunningApplication(processIdentifier: pid) else { return (false, "activate", nil) }
    if #available(macOS 14, *) { return (app.activate(), "activate", nil) }
    return (app.activate(options: [.activateIgnoringOtherApps]), "activate", nil)
}

/// After Tim switched to `pid` himself: the window yabai reports focused becomes his restore target once it is
/// that app's (yabai can lag the switch by some ms, so a few tries).
func refreshTarget(_ pid: pid_t, attempt: Int = 0) {  // timQueue
    guard !stopping.value, restoreTarget.value.pid == pid else { return }
    if let w = yabai(["query", "--windows", "--window"], timeout: 0.5) as? [String: Any],
       let id = (w["id"] as? NSNumber)?.intValue, let owner = (w["pid"] as? NSNumber)?.int32Value {
        let ownerInTree = tree.contains(owner)
        if restoreTarget.update({ $0.focused(id, owner: owner, ownerInTree: ownerInTree) }) {
            emit(["event": "restore-target", "pid": Int(owner), "window": id])
            return
        }
    }
    if attempt < 5 { timQueue.asyncAfter(deadline: .now() + 0.03) { refreshTarget(pid, attempt: attempt + 1) } }
}

var unrestorableReported: Double?  // timQueue: the theft whose unrestorable Space jump was reported
var spacePollScheduled = false     // timQueue

func checkSpace() {  // timQueue
    guard !stopping.value, let visible = timDisplaySpace() else { return }
    let window = restoreTarget.value.window
    var windowSpace: Int?
    if let expected = spacePolicy.value.expected, visible != expected, let window {
        windowSpace = (windowInfo(window)?["space"] as? NSNumber)?.intValue
    }
    let t = uptime() - t0
    let (decision, theftAt) = spacePolicy.update { ($0.observed(visible, at: t, window: window, windowSpace: windowSpace), $0.theftAt) }
    switch decision {
    case .unchanged:
        break
    case .user(let shown):
        emit(["event": "user-space", "space": shown])
    case .restore(let from, let to, let window):
        _ = yabai(["window", "--focus", String(window)])
        var after = timDisplaySpace()
        for _ in 0..<5 where after != to {
            usleep(50_000)
            after = timDisplaySpace()
        }
        var record: [String: Any] = ["event": "space-restored", "from": from, "to": after ?? NSNull(), "window": window, "ok": after == to]
        record["latencyMs"] = theftAt.map { ms(uptime() - t0 - $0) } ?? NSNull()
        spaceEvents.update { $0.append(record) }
        emit(record)
    case .unrestorable(let from, let to):
        guard unrestorableReported != theftAt else { break }
        unrestorableReported = theftAt
        let record: [String: Any] = ["event": "space-unrestorable", "from": from, "to": to, "window": window ?? NSNull()]
        spaceEvents.update { $0.append(record) }
        emit(record)
    }
}

/// Checks Tim's Space every 100 ms while within the grace after a tree activation: macOS switches Spaces some
/// ms after the activation, possibly after the revert.
func pollSpace() {  // timQueue
    guard !spacePollScheduled else { return }
    spacePollScheduled = true
    timQueue.asyncAfter(deadline: .now() + 0.1) {
        spacePollScheduled = false
        checkSpace()
        if spacePolicy.value.inGrace(at: uptime() - t0) { pollSpace() }
    }
}

// MARK: - Activations (main thread)

func onActivation(_ app: NSRunningApplication, at t: Double) {
    let pid = app.processIdentifier
    let inTree = tree.adopt(pid, via: "activation")
    let decision = policy.activation(pid: pid, inTree: inTree, at: t - t0)
    let now = iso()
    switch decision {
    case .restore(let to):
        let result = restoreFocus(to: to)
        let called = uptime()
        lastRestore = (result.method, result.window)
        if theft == nil { theft = ["app": describe(app), "activatedAt": now, "t": t] }
        emit(["event": "activation", "app": describe(app), "tree": true, "decision": "restore", "to": Int(to),
              "restoreMethod": result.method, "restoreWindow": result.window ?? NSNull(), "restoreCallOk": result.ok,
              "restoreCallMs": ms(called - t), "at": now])
        let theftAt = t - t0
        timQueue.async {
            spacePolicy.update { $0.theft(at: theftAt) }
            pollSpace()
        }
        observe(pid)
        yabaiQueue.async { sweep("activation") }
    case .restored(let latency):
        var record: [String: Any] = ["event": "reverted", "to": describe(app), "restoredAt": now, "latencyMs": ms(latency),
                                     "method": lastRestore.method, "window": lastRestore.window ?? NSNull()]
        if let theft {
            record["stolenBy"] = theft["app"]
            record["activatedAt"] = theft["activatedAt"]
        }
        theft = nil
        reverted.append(record)
        emit(record)
        timQueue.async { checkSpace() }
    case .user:
        if theft != nil { emit(["event": "restore-superseded", "by": describe(app), "at": now]) }
        theft = nil
        restoreTarget.update { $0.userSwitched(to: pid) }
        timQueue.async { refreshTarget(pid) }
        emit(["event": "activation", "app": describe(app), "tree": false, "decision": "user", "at": now])
    case .unrestorable:
        emit(["event": "activation", "app": describe(app), "tree": true, "decision": "unrestorable", "at": now])
        let theftAt = t - t0
        timQueue.async { spacePolicy.update { $0.theft(at: theftAt) } }
    case .afterGuard:
        break
    }
}

let center = workspace.notificationCenter
center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil) { note in
    let t = uptime()
    guard !finished, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
    onActivation(app, at: t)
}
center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: nil) { note in
    guard !finished, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
    if tree.adopt(app.processIdentifier, via: "launch") { observe(app.processIdentifier) }
}
center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: nil) { _ in
    yabaiQueue.async { sweep("space-change") }
    timQueue.async { checkSpace() }
}
center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: nil) { _ in
    if mode != nil && !attaching && tree.hasRoots && !tree.anyAlive { finish("tree-exited") }
}
let appsObservation = workspace.observe(\.runningApplications, options: [.new]) { _, change in
    for app in change.newValue ?? [] where tree.adopt(app.processIdentifier, via: "launch") { observe(app.processIdentifier) }
}

// MARK: - The scan (scanQueue)

func scanOnce() {
    let adopted = tree.scan()
    for pid in adopted { observe(pid) }
    if !adopted.isEmpty { yabaiQueue.async { sweep("attached") } }
}

var scanTimer: DispatchSourceTimer?
if mode == "open" || attaching {
    let timer = DispatchSource.makeTimerSource(queue: scanQueue)
    timer.schedule(deadline: .now(), repeating: .milliseconds(150), leeway: .milliseconds(20))
    timer.setEventHandler { if !stopping.value { scanOnce() } }
    timer.resume()
    scanTimer = timer
}

// MARK: - End

/// Ends the guard promptly: queued yabai work is abandoned (only the final sweep runs), and nothing waits on
/// another queue.
var finishing = false
func finish(_ reason: String) {  // main
    guard !finishing else { return }
    finishing = true
    stopping.update { $0 = true }
    scanTimer?.cancel()
    let orphaned = reason == "parent-exited"
    if !orphaned {
        if mode == "open" || attaching { _ = tree.scan() }
        sweep("final", final: true)
        // Let a restore issued just now land before reading the frontmost app.
        let wait = Date().addingTimeInterval(0.2)
        while theft != nil && Date() < wait { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    }
    finished = true
    var reason = reason
    var fault: String?
    if mode == "open" && launchFailure == nil && !tree.hasRoots {
        fault = String(format: "no process carrying this launch's GUI_LAUNCH_TOKEN (sha256 %@) appeared in %.1f s: the launch may be running unguarded",
                       tokenHash, uptime() - (launchedAt ?? t0))
        emit(["event": "fault", "message": fault!])
    }
    if let launchFailure {
        reason = "error"
        emit(["event": "error", "message": launchFailure])
    }
    if orphaned {
        unlink(summaryPath)  // gui-launch is gone: nobody reads it
    } else {
        let focusAtEnd = focusContext()
        var summary = tree.summary
        summary.merge([
            "space": space, "guardSeconds": guardSeconds, "endReason": reason, "error": launchFailure ?? NSNull(),
            "fault": fault ?? NSNull(), "token": tokenHash,
            "frontAtLaunch": describe(frontAtLaunch), "frontAtEnd": describe(workspace.frontmostApplication),
            "userFront": describe(policy.userFront.flatMap { NSRunningApplication(processIdentifier: $0) }),
            "restorePending": theft != nil, "focusAtLaunch": focusAtLaunch, "focusAtEnd": focusAtEnd,
            "timSpace": ["atLaunch": timSpaceAtLaunch ?? NSNull(), "expected": spacePolicy.value.expected ?? NSNull()] as [String: Any],
            "reverted": reverted, "moves": moves.value, "spaceRestores": spaceEvents.value, "problems": problems.value,
        ]) { _, new in new }
        let data = try! JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys, .withoutEscapingSlashes])
        FileManager.default.createFile(atPath: summaryPath, contents: data)
    }
    emit(["event": "guard-end", "reason": reason, "seconds": decimal(uptime() - t0, 3), "reverted": reverted.count,
          "moved": moves.value.filter { $0["moved"] as? Bool == true }.count])
    if let launchFailure {
        complain(launchFailure)
        exit(2)
    }
    exit(0)
}

var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler { finish("signal") }
    source.resume()
    signalSources.append(source)
}
// gui-launch's exit, even by SIGKILL, ends the guard (kqueue EVFILT_PROC NOTE_EXIT).
var parentSource: DispatchSourceProcess?
if let parentWatch {
    let source = DispatchSource.makeProcessSource(identifier: parentWatch, eventMask: .exit, queue: .main)
    source.setEventHandler { finish("parent-exited") }
    source.resume()
    parentSource = source
    if processStart(parentWatch) == nil { fail("gui-launch (pid \(parentWatch)) exited before the guard was up") }
}

// MARK: - Launch

// The guard is up: a caller may watch or signal it (it runs as the caller's user, in sudo's process group).
emit(["event": "guard", "pid": Int(getpid()), "pgid": Int(getpgrp()), "start": processStart(getpid()).map { NSNumber(value: $0) } ?? NSNull()])

let attachRecord: Any = matcher.map { ["exe": $0.exe, "needle": attachNeedle ?? ""] as [String: Any] } ?? NSNull()
var spawnedPid: pid_t = 0
if launchArgv.isEmpty {
    emit(["event": "guarding", "space": space, "guardSeconds": guardSeconds, "front": describe(frontAtLaunch),
          "focus": focusAtLaunch, "timSpace": timSpaceAtLaunch ?? NSNull(), "restoreWindow": restoreTarget.value.window ?? NSNull(),
          "attach": attachRecord])
} else {
    let entry = "GUI_LAUNCH_TOKEN=\(token)"
    var spawnArgv = launchArgv
    var environment = ProcessInfo.processInfo.environment.filter { $0.key != "GUI_LAUNCH_TOKEN" }.map { "\($0.key)=\($0.value)" }
    if mode == "open" { spawnArgv.insert(contentsOf: ["--env", entry], at: 1) } else { environment.append(entry) }
    var fileActions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&fileActions)
    posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_adddup2(&fileActions, 2, 1)  // stdout carries only our events
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))  // a Ctrl-C on gui-launch spares the app
    posix_spawnattr_setpgroup(&attributes, 0)
    let cArgs = spawnArgv.map { strdup($0) } + [nil]
    let cEnv = environment.map { strdup($0) } + [nil]
    let spawned = posix_spawnp(&spawnedPid, spawnArgv[0], &fileActions, &attributes, cArgs, cEnv)
    guard spawned == 0 else { fail("cannot run \(spawnArgv[0]): \(String(cString: strerror(spawned)))") }
    launchedAt = uptime()
    if mode == "exec" {
        tree.addRoot(spawnedPid)
        observe(spawnedPid)
    }
    emit(["event": "launched", "argv": spawnArgv.map { $0 == entry ? "GUI_LAUNCH_TOKEN=<sha256 \(tokenHash)>" : $0 },
          "pid": Int(spawnedPid), "token": tokenHash, "space": space, "guardSeconds": guardSeconds,
          "front": describe(frontAtLaunch), "focus": focusAtLaunch, "timSpace": timSpaceAtLaunch ?? NSNull(),
          "restoreWindow": restoreTarget.value.window ?? NSNull(), "attach": attachRecord])
    // Reap the spawned process on its own thread (a dispatch exit source can miss a fast `open`).
    DispatchQueue.global().async {
        var status: Int32 = 0
        while waitpid(spawnedPid, &status, 0) == -1 && errno == EINTR {}
        DispatchQueue.main.async {
            if mode == "exec" {
                if !attaching && !tree.anyAlive { finish("tree-exited") }
                return
            }
            // `open` has returned: the app is launched (its token-bearing process may still be some way off), or open failed.
            let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
            if code != 0 {
                launchFailure = "open exited \(code)"
                finish("error")
            }
            scanQueue.async { if !stopping.value { scanOnce() } }
        }
    }
    if mode == "open" {
        DispatchQueue.main.asyncAfter(deadline: .now() + adoptTimeout) { if !tree.hasRoots { finish("no-launch") } }
    }
}

Timer.scheduledTimer(withTimeInterval: guardSeconds, repeats: false) { _ in finish("timeout") }
RunLoop.main.run()
