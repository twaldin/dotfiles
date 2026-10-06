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
// of all processes every 150 ms (the token is read only from processes the snapshot taken before the launch did
// not see: a pid absent from it, or one now naming a process with another start time). Attach members already
// running are adopted before the baseline is taken.
// Before anything launches, the guard takes its baseline: Tim's front app, his focused window and its Space (the
// restore target, if the window is that app's and the app is outside the tree) and the Space his display shows.
// A yabai call there that fails or misses its deadline is an error (exit 2): nothing launches.
// Until the guard ends it
//   - attributes: an activation or a Space change is Tim's own only with his HID input (keyboard, mouse) after
//     the last tree theft and within 1 s before it; an app macOS activates without it never becomes his;
//   - reverts activations: when a tree process becomes frontmost, it focuses Tim's restore-target window by its
//     cached id (no query on this path; a window that is gone fails the focus harmlessly), or re-activates his
//     app when there is none or the focus fails. The target is his focused window at launch or after an app
//     switch of his own, never a tree member's window; before every focus its app is checked again (the same
//     process, by pid and start time, outside the tree) and dropped if it joined the tree;
//   - restores Tim's Space: a change of his display's Space while a tree theft is open, within 2 s after it was
//     given back, or that stays on the Space the tree took it to is the tree's unless he switched apps himself
//     since the theft and gave input within 1 s; focusing the restore target, when it was last seen on the
//     expected Space, brings that Space back. Every such change is recorded: a breach even when restored;
//   - parks windows: each tree window that Accessibility reports created or focused, and each tree window
//     yabai lists when the tree activates or the active Space changes, is moved by id to --space.
// The guard ends after --guard-seconds; when the launched tree has exited (without attach flags); when
// --parent-pid (gui-launch) exits, even by SIGKILL; on SIGTERM/SIGINT; or (--open) when no token-bearing
// process appeared within --adopt-timeout. On every end no new work starts; work in flight gets 3 s to settle
// (what does not is a problem for the check); then every yabai helper still running is killed with its process
// group (SIGTERM, then SIGKILL) and reaped; nothing is printed after guard-end. It never quits what it launched.
// Events go to stdout as JSON lines; the summary gui-launch checks goes to --summary.
// Threads: main handles workspace notifications, signals and gui-launch's exit, and never waits on a child
// process (a yabai call there is refused, and is a problem); reverts run on restoreQueue, Accessibility calls on
// axQueue (observer callbacks on their own run loop thread), window moves on yabaiQueue, Tim's restore target
// and Space on timQueue, the process scan on scanQueue, the baseline on startQueue and the end on endQueue.
// Every yabai call has one deadline over its exit and the drain of its output.
//
// usage: gui-launch-guard --space N --guard-seconds S --yabai PATH --summary PATH [--parent-pid P]
//            [--adopt-timeout S] [--attach-exe E --attach-argv N] [(--exec | --open) -- <argv to spawn>]
//        gui-launch-guard --screens   screen name -> CGDirectDisplayID (yabai's display "id"), as JSON
//        gui-launch-guard --decide    tree, restore and Space decisions for synthetic processes on stdin (tests)
//        gui-launch-guard --resolve [--token T] [--attach-exe E --attach-argv N]
//                                     tree decisions for live processes named on stdin (tests)
//        gui-launch-guard --helpers --yabai PATH
//                                     yabai calls and the guard's end, driven from stdin (tests)
// build: swiftc -O -swift-version 5 -target arm64-apple-macos13 \
//          -o ~/.local/bin/gui-launch-guard src/gui-launch-guard.swift
import AppKit
import ApplicationServices
import CryptoKit
import Security

// MARK: - Decisions (pure; --decide feeds them synthetic processes, activations, input and Spaces)

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
    /// Not the process the pre-launch snapshot saw under this pid (pid, start time): absent from it, or a
    /// process that started at another time under a reused pid.
    var isNew: (pid_t, UInt64) -> Bool
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
        let byToken = tokenEntry != nil && source.isNew(pid, start)
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

/// How recent Tim's input must be for a change to count as his own.
let inputWindow = 1.0

/// Whether Tim's HID input (keyboard, mouse) makes a change at `t` his own: it came after the last tree theft
/// and within `inputWindow` before the change. Times are seconds since launch; nil: none.
func timsInput(_ input: Double?, at t: Double, after theft: Double?) -> Bool {
    guard let input, input <= t, t - input <= inputWindow else { return false }
    return theft.map { input > $0 } ?? true
}

/// What to do when an app becomes frontmost. `userFront` is the app to give focus back to: the frontmost app
/// at launch (if it is outside the tree), then whichever app outside the tree Tim last switched to himself.
struct RestorePolicy {
    enum Decision: Equatable {
        case restore(to: pid_t)            // a tree process took focus: give it back
        case restored(latency: Double)     // the user's app is frontmost again; seconds since the theft
        case user                          // Tim's own switch to an app outside the tree: his new choice
        case system                        // an app outside the tree without his input: macOS's choice, not his
        case unrestorable                  // a tree process took focus and there is no app to give it back to
        case afterGuard
    }

    private(set) var userFront: pid_t?
    let guardUntil: Double
    /// When the tree took focus that is not yet given back.
    private(set) var pendingSince: Double?
    /// The last tree activation.
    private(set) var lastTheft: Double?

    init(userFront: pid_t?, guardUntil: Double) {
        self.userFront = userFront
        self.guardUntil = guardUntil
    }

    /// `input`: when Tim's last HID input came.
    mutating func activation(pid: pid_t, inTree: Bool, at t: Double, input: Double?) -> Decision {
        if t > guardUntil { return .afterGuard }
        if inTree {
            lastTheft = t
            guard let to = userFront else { return .unrestorable }
            if pendingSince == nil { pendingSince = t }
            return .restore(to: to)
        }
        if pid == userFront, let since = pendingSince {
            pendingSince = nil
            return .restored(latency: t - since)
        }
        guard timsInput(input, at: t, after: lastTheft) else { return .system }
        userFront = pid
        pendingSince = nil
        return .user
    }

    /// The app focus goes back to joined the tree or is gone: there is none until Tim picks one.
    mutating func forgetUserFront() {
        userFront = nil
        pendingSince = nil
    }
}

/// The window a revert focuses, with the Space it was last verified on (off the main thread): Tim's focused
/// window at launch, then, after each of his own app switches, the window yabai reports focused once it belongs
/// to the app he switched to. The app is remembered with its start time. A tree activation or a system-chosen
/// app never changes it; a window whose owner is in the tree (lineage, token or attach), or is the app he left
/// (yabai lagging), is never taken; and before every focus the app is checked again: one that is now another
/// process or in the tree is dropped, with its window.
struct RestoreTarget: Equatable {
    private(set) var pid: pid_t?
    private(set) var start: UInt64?
    private(set) var window: Int?
    private(set) var windowSpace: Int?

    /// No target without a live process.
    init(pid: pid_t?, start: UInt64?) {
        guard let pid, let start else { return }
        self.pid = pid
        self.start = start
    }

    /// The window to focus to give focus back to `app`, if it is the target's.
    func window(for app: pid_t) -> Int? { app == pid ? window : nil }

    /// Tim switched to `app` himself, outside the tree: its window is not known yet (unless it is the same app).
    mutating func userSwitched(to app: pid_t, start: UInt64?) {
        if app == pid && start == self.start { return }
        self = RestoreTarget(pid: app, start: start)
    }

    /// yabai reports window `id` of `owner` (started at `ownerStart`) on `space`; returns whether it is the
    /// target now.
    mutating func verified(_ id: Int, owner: pid_t, ownerStart: UInt64?, ownerInTree: Bool, space: Int?) -> Bool {
        guard !ownerInTree, owner == pid, ownerStart != nil, ownerStart == start else {
            if id == window { located(id, space: nil) }  // the cached window turned out not to be his
            return false
        }
        window = id
        windowSpace = space
        return true
    }

    /// The target window's Space as last verified; nil: yabai no longer knows the window.
    mutating func located(_ id: Int, space: Int?) {
        guard id == window else { return }
        if space == nil { window = nil }
        windowSpace = space
    }

    /// Before a focus: the target's app is still the process it was taken from (`current`: its start time now)
    /// and outside the tree. Otherwise there is no target any more.
    mutating func revalidate(start current: UInt64?, inTree: Bool) -> Bool {
        guard pid != nil else { return false }
        if inTree || current == nil || current != start {
            self = RestoreTarget(pid: nil, start: nil)
            return false
        }
        return true
    }
}

/// The Space Tim's display should show. A change of it counts as his own only with his input (`timsInput`), and
/// within a theft window (a tree theft not yet given back, `grace` after it was, or the display still on the
/// Space the tree took it to) only once he switched apps himself since the theft. Without that, a change in a
/// theft window is the tree's: restore it by focusing his restore-target window, if that window was last seen on
/// the expected Space. Any other change without his input is unexplained: nothing is restored. Neither ever
/// changes the expected Space.
struct SpacePolicy {
    enum Decision: Equatable {
        case unchanged
        case user(Int)
        case restore(from: Int, to: Int, window: Int)
        case unrestorable(from: Int, to: Int)
        case unexplained(shown: Int, expected: Int)
    }

    static let grace = 2.0
    private(set) var expected: Int?
    /// The last tree activation.
    private(set) var theftAt: Double?
    /// A theft not yet given back.
    private(set) var open = false
    private(set) var givenBackAt: Double?
    /// Tim switched apps himself (with input) since the last theft.
    private(set) var timSwitched = false
    /// The Space the tree moved Tim's display to, while it still shows it.
    private(set) var thiefSpace: Int?

    init(expected: Int?) { self.expected = expected }

    mutating func theft(at t: Double) {
        theftAt = t
        open = true
        givenBackAt = nil
        timSwitched = false
    }

    mutating func givenBack(at t: Double) {
        guard open else { return }
        open = false
        givenBackAt = t
    }

    mutating func timActivated(at t: Double) {
        givenBack(at: t)
        timSwitched = true
    }

    func inTheftWindow(at t: Double) -> Bool {
        guard let theftAt else { return false }
        return open || t - (givenBackAt ?? theftAt) <= SpacePolicy.grace
    }

    /// Whether to poll Tim's Space: within `grace` of the last theft or of its return (macOS switches Spaces
    /// some ms after an activation, possibly after the revert).
    func polling(at t: Double) -> Bool {
        guard let theftAt else { return false }
        return t - max(theftAt, givenBackAt ?? theftAt) <= SpacePolicy.grace
    }

    /// Tim's display shows `visible` at `t`; `input` is when his last HID input came; `window` is his restore
    /// target and `windowSpace` the Space it was last verified on (nil: gone).
    mutating func observed(_ visible: Int, at t: Double, input: Double?, window: Int?, windowSpace: Int?) -> Decision {
        guard let want = expected else { return .unchanged }
        if visible == want {
            thiefSpace = nil
            return .unchanged
        }
        let theftWindow = visible == thiefSpace || inTheftWindow(at: t)
        if timsInput(input, at: t, after: theftAt) && (!theftWindow || timSwitched) {
            expected = visible
            thiefSpace = nil
            return .user(visible)
        }
        guard theftWindow else { return .unexplained(shown: visible, expected: want) }
        thiefSpace = visible
        guard let window, windowSpace == want else { return .unrestorable(from: visible, to: want) }
        return .restore(from: visible, to: want, window: window)
    }
}

// MARK: - Output

signal(SIGPIPE, SIG_IGN)
let outLock = NSLock()
var outputClosed = false  // outLock: after guard-end (or the error that ends the guard) nothing is printed
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

func writeLine(_ object: [String: Any], last: Bool = false) {
    guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
    data.append(10)
    outLock.lock(); defer { outLock.unlock() }
    guard !outputClosed else { return }
    data.withUnsafeBytes { _ = write(1, $0.baseAddress, $0.count) }
    if last { outputClosed = true }
}

func emit(_ event: [String: Any], last: Bool = false) {
    var record = event
    if record["at"] == nil { record["at"] = iso() }
    writeLine(record, last: last)
}

func complain(_ message: String) {
    FileHandle.standardError.write(("gui-launch-guard: " + message + "\n").data(using: .utf8)!)
}

func fail(_ message: String) -> Never {
    emit(["event": "error", "message": message], last: true)
    complain(message)
    _ = helpers.shutdown()
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

/// Problems the check must report: yabai calls that ran out of time or were refused, work that did not settle
/// by the guard's end, helpers killed then.
let problems = Locked([String]())

func problem(_ message: String) {
    problems.update { $0.append(message) }
    emit(["event": "problem", "message": message])
}

// MARK: - Child processes and work in flight

/// posix_spawn attributes for a child: SIGTERM, SIGINT and SIGPIPE at their defaults (the guard ignores them, and
/// an ignored signal stays ignored across exec), no signal blocked, its own process group, and with
/// `onlyListedFds` no descriptor but those its file actions set up.
func childAttributes(onlyListedFds: Bool) -> posix_spawnattr_t? {
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    var defaults = sigset_t()
    sigemptyset(&defaults)
    for sig in [SIGTERM, SIGINT, SIGPIPE] { sigaddset(&defaults, sig) }
    posix_spawnattr_setsigdefault(&attributes, &defaults)
    var unblocked = sigset_t()
    sigemptyset(&unblocked)
    posix_spawnattr_setsigmask(&attributes, &unblocked)
    var flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
    if onlyListedFds { flags |= POSIX_SPAWN_CLOEXEC_DEFAULT }
    posix_spawnattr_setflags(&attributes, Int16(flags))
    posix_spawnattr_setpgroup(&attributes, 0)
    return attributes
}

/// A spawned helper, the leader of its own process group: its output, drained, and its exit, reaped, under one
/// deadline.
struct Child {
    let pid: pid_t
    let output: Int32
    private(set) var data = Data()
    private(set) var eof = false
    private(set) var reaped = false
    private var status: Int32 = 0

    init(pid: pid_t, output: Int32) {
        self.pid = pid
        self.output = output
        _ = fcntl(output, F_SETFL, O_NONBLOCK)
    }

    var code: Int32 { (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f) }

    /// Reads what output there is and reaps the child if it exited, without blocking.
    private mutating func step() {
        var buffer = [UInt8](repeating: 0, count: 16384)
        while !eof {
            let n = read(output, &buffer, buffer.count)
            if n > 0 { data.append(contentsOf: buffer[..<n]); continue }
            if n < 0 && errno == EINTR { continue }
            if n == 0 || errno != EAGAIN { eof = true }
            break
        }
        if !reaped {
            let r = waitpid(pid, &status, WNOHANG)
            if r == pid || (r == -1 && errno == ECHILD) { reaped = true }
        }
    }

    /// Until the child has exited and its output is closed (by it and anything it started), or `deadline`
    /// (uptime) passes. Returns whether it finished.
    mutating func wait(until deadline: Double) -> Bool {
        while true {
            step()
            if eof && reaped { return true }
            let left = deadline - uptime()
            if left <= 0 { return false }
            if eof {
                usleep(UInt32(min(left, 0.001) * 1_000_000))
            } else {
                var ready = pollfd(fd: output, events: Int16(POLLIN), revents: 0)
                _ = poll(&ready, 1, Int32((left * 1000).rounded(.up)))
            }
        }
    }

    /// Kills the child's process group (the child and whatever it started that still holds its output): SIGTERM,
    /// then SIGKILL if that has not ended it within 0.3 s. Returns whether it was reaped and its output closed.
    mutating func stop() -> Bool {
        killpg(pid, SIGTERM)
        if wait(until: uptime() + 0.3) { return true }
        // Its group still exists: the leader is unreaped, or a member holds the output open.
        killpg(pid, SIGKILL)
        return wait(until: uptime() + 0.5)
    }
}

/// Whether this code runs on the main thread or the main queue (which dispatchMain() serves from another thread).
let mainQueueKey = DispatchSpecificKey<Bool>()
DispatchQueue.main.setSpecific(key: mainQueueKey, value: true)
func onMain() -> Bool { Thread.isMainThread || DispatchQueue.getSpecific(key: mainQueueKey) == true }

/// The guard's yabai helpers. Each runs in its own process group under one absolute deadline over its exit and
/// the drain of its output; one that misses it is killed with its group, reaped and reported (a problem and a
/// yabai-timeout event). None runs on the main thread or queue (refused, and a problem), none starts after shutdown(),
/// and shutdown() kills those still running.
final class Helpers {
    enum Reply {
        case exited(Int32, Data)
        case timedOut
        case refused(String)
    }

    private let lock = NSLock()
    private var running: [pid_t: String] = [:]
    /// Killed by shutdown().
    private var ended = Set<pid_t>()
    private var closed = false
    /// No call's deadline is later (uptime), once the guard is ending.
    private var cap = Double.infinity

    func endBy(_ deadline: Double) {
        lock.lock(); defer { lock.unlock() }
        cap = min(cap, deadline)
    }

    func run(_ path: String, _ args: [String], timeout: Double) -> Reply {
        let what = "yabai -m " + args.joined(separator: " ")
        if onMain() {
            let message = "\(what) was asked for on the main thread, which never waits on a child process: refused"
            problem(message)
            return .refused(message)
        }
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { return .refused("no pipe for \(what): \(String(cString: strerror(errno)))") }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, fds[1], 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        var attributes = childAttributes(onlyListedFds: true)
        let argv = ([path, "-m"] + args).map { strdup($0) } + [nil]
        var pid: pid_t = 0
        var spawned: Int32 = -1
        lock.lock()
        let begun = uptime()
        let allowed = min(timeout, cap - begun)
        let deadline = begun + allowed
        if !closed && begun < deadline {
            spawned = posix_spawn(&pid, path, &actions, &attributes, argv, environ)
            if spawned == 0 { running[pid] = what }
        }
        lock.unlock()
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attributes)
        argv.forEach { free($0) }
        close(fds[1])
        guard spawned == 0 else {
            close(fds[0])
            return .refused(spawned == -1 ? "the guard is ending: \(what) not run" : "cannot run \(path): \(String(cString: strerror(spawned)))")
        }
        var child = Child(pid: pid, output: fds[0])
        let finished = child.wait(until: deadline)
        let reaped = finished || child.stop()
        close(fds[0])
        lock.lock()
        running[pid] = nil
        let killedAtEnd = ended.remove(pid) != nil
        lock.unlock()
        if !reaped { problem("\(what) (pid \(pid)) could not be killed and reaped") }
        if killedAtEnd { return .refused("\(what) was killed at the guard's end") }
        guard finished else {
            let seconds = String(format: "%.1f", allowed)
            problems.update { $0.append("\(what) did not answer within \(seconds) s") }
            emit(["event": "yabai-timeout", "args": args, "timeoutS": decimal(allowed, 1)])
            return .timedOut
        }
        return .exited(child.code, child.data)
    }

    /// The guard's end: no helper starts any more, and each still running is killed with its process group
    /// (SIGTERM, then SIGKILL after 0.3 s) and reaped by the call that started it. Returns what they were.
    func shutdown() -> [String] {
        lock.lock()
        closed = true
        let victims = running
        ended.formUnion(victims.keys)
        lock.unlock()
        guard !victims.isEmpty else { return [] }
        for pid in victims.keys { killpg(pid, SIGTERM) }
        if !gone(Array(victims.keys), within: 0.3) {
            lock.lock()
            let left = victims.keys.filter { running[$0] != nil }
            lock.unlock()
            for pid in left { killpg(pid, SIGKILL) }
            _ = gone(left, within: 0.6)
        }
        return victims.values.sorted()
    }

    private func gone(_ pids: [pid_t], within seconds: Double) -> Bool {
        let until = uptime() + seconds
        while true {
            lock.lock()
            let any = pids.contains { running[$0] != nil }
            lock.unlock()
            if !any { return true }
            if uptime() >= until { return false }
            usleep(2_000)
        }
    }
}

/// Work that may run a yabai helper (a park, a sweep, a Space check, a restore-target refresh, a revert, the
/// baseline): the guard's end waits for it, boundedly, so none of its events or timeouts is lost.
final class InFlight {
    private let condition = NSCondition()
    private var active: [Int: String] = [:]
    private var next = 0
    private var closed = false

    var isClosed: Bool {
        condition.lock(); defer { condition.unlock() }
        return closed
    }

    /// nil: the guard is ending and this work is not `final` (the end's own, or a revert of a theft).
    func begin(_ what: String, final: Bool = false) -> Int? {
        condition.lock(); defer { condition.unlock() }
        guard final || !closed else { return nil }
        next += 1
        active[next] = what
        return next
    }

    func end(_ id: Int) {
        condition.lock()
        active[id] = nil
        condition.broadcast()
        condition.unlock()
    }

    func close() {
        condition.lock(); defer { condition.unlock() }
        closed = true
    }

    /// Waits until no work is in flight or `seconds` pass; returns the work still in flight.
    func settle(within seconds: Double) -> [String] {
        let limit = Date().addingTimeInterval(seconds)
        condition.lock(); defer { condition.unlock() }
        while !active.isEmpty && condition.wait(until: limit) {}
        return active.values.sorted()
    }
}

let helpers = Helpers()
let inFlight = InFlight()
var stopping: Bool { inFlight.isClosed }

func tracked(_ what: String, final: Bool = false, _ body: () -> Void) {
    guard let id = inFlight.begin(what, final: final) else { return }
    defer { inFlight.end(id) }
    body()
}

/// How long work in flight gets to finish once the guard ends, and how long the end's own work may then take.
let settleSeconds = 3.0
let finalSeconds = 3.0

/// The guard's end, on every path (and in --helpers), once inFlight is closed: work in flight gets
/// `settleSeconds`; `finalWork` runs (no yabai call past `finalSeconds` more); then every helper still running is
/// killed and reaped, and the work that lost its helper gets a moment to unwind. Work that did not settle, and
/// each helper killed, is a problem. Never on main.
func endWork(_ finalWork: () -> Void) -> (unsettled: [String], killed: [String]) {
    helpers.endBy(uptime() + settleSeconds + finalSeconds)
    let unsettled = inFlight.settle(within: settleSeconds)
    for what in unsettled { problem("\(what) was still running \(settleSeconds) s into the guard's end") }
    finalWork()
    let killed = helpers.shutdown()
    for what in killed { problem("\(what) was still running at the guard's end: killed") }
    _ = inFlight.settle(within: 0.5)
    return (unsettled, killed)
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

/// Every process now, by pid, with its start time: the pre-launch snapshot.
func liveStarts() -> [pid_t: UInt64] {
    var starts: [pid_t: UInt64] = [:]
    for pid in allPids() {
        if let start = processStart(pid) { starts[pid] = start }
    }
    return starts
}

/// The live tree: Lineage on live process facts behind a lock, reporting adoptions and drops as events.
final class Tree {
    private let lock = NSLock()
    private var lineage: Lineage
    /// The processes before the launch, by pid and start time.
    private let snapshot: [pid_t: UInt64]
    private var realPaths: [String: String] = [:]
    /// The scan's: processes checked and not adopted.
    private var checked: [pid_t: Sighting] = [:]
    private var adoptions: [[String: Any]] = []
    private var drops: [[String: Any]] = []
    private let t0: Double
    private let tokenHash: String?
    private let needle: String?

    init(_ lineage: Lineage, snapshot: [pid_t: UInt64], t0: Double, tokenHash: String?, needle: String?) {
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
                   isNew: { self.snapshot[$0] != $1 })
    }

    func addRoot(_ pid: pid_t) {
        lock.lock(); defer { lock.unlock() }
        lineage.addRoot(pid, start: processStart(pid) ?? 0)
    }

    /// Membership only, as before a window move: never adopts.
    func contains(_ pid: pid_t) -> Bool { resolve(pid, via: nil) }

    /// An adoption point (an activation, an app launch, a restore-target check): pid is in the tree, or it or an
    /// ancestor is adopted.
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
    /// reads only processes the pre-launch snapshot did not see, by pid and start time; the attach rule only
    /// those running --attach-exe). A process checked and not adopted is skipped until its Sighting changes.
    /// Returns the pids adopted.
    func scan() -> [pid_t] {
        let pids = allPids()
        lock.lock(); defer { lock.unlock() }
        let live = Set(pids)
        checked = checked.filter { live.contains($0.key) }
        let me = getpid()
        var adopted: [pid_t] = []
        for pid in pids where pid != me && lineage.members[pid] == nil {
            guard let info = bsdInfo(pid) else { continue }
            let sighting = Sighting(info)
            guard lineage.matcher != nil || snapshot[pid] != sighting.start else { continue }
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

/// stdin: a header `{"front": pid|null, "frontWindow": id|null, "frontWindowSpace": n|null, "guardSeconds": S,
/// "token": T, "attach": {"exe", "needle"}, "before": [pid], "roots": [pid], "timSpace": n, "input": t|null,
/// "procs": [...]}` (all but front and guardSeconds optional), then rows. `procs`, `[{"pid", "ppid", "start",
/// "exe", "argv", "env", "unreadable"}]`, defines synthetic processes (replacing any with the same pid; "start":
/// null means gone, absent means 1; "unreadable": true hides its arguments and environment); "before" pids are
/// snapshotted with their start times then. In the header, as at the guard's start, attach members among the
/// header's procs join the tree before the front app and its window become the restore target. A row may set
/// `"input": t`, when Tim's last HID input came (it stays until changed). Its action is one of
/// `{"t", "activate": pid, "focused": {"id", "pid", "space"}}` (an activation; `focused` is the window yabai
/// reports focused afterwards, optional), `{"t", "launch": pid}` (an app launch or a scan sighting),
/// `{"t", "move": pid}` (the check before a window move), `{"t", "space": n, "windowSpace": n|null}` (the Space
/// Tim's display shows; windowSpace, optional, is the Space his restore-target window was last verified on, null:
/// gone). stdout: one line per action.
func decide() -> Never {
    var procs: [pid_t: [String: Any]] = [:]
    var before: [pid_t: UInt64] = [:]
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
        args: { p in
            guard let row = procs[p], row["unreadable"] as? Bool != true else { return nil }
            return ProcArgs(argv: strings(row["argv"]), env: strings(row["env"]))
        },
        isNew: { before[$0] != $1 })
    var policy = RestorePolicy(userFront: nil, guardUntil: 0)
    var lineage = Lineage(tokenEntry: nil, matcher: nil)
    var target = RestoreTarget(pid: nil, start: nil)
    var spaces = SpacePolicy(expected: nil)
    var input: Double?
    var started = false
    func inTree(_ p: pid_t) -> Bool { lineage.resolve(p, adopting: true, source).inTree }
    /// The app focus goes back to, checked as before every focus; returns it if it was dropped.
    func revalidate() -> pid_t? {
        guard let u = policy.userFront else { return nil }
        if target.pid == u && target.revalidate(start: source.start(u), inTree: inTree(u)) { return nil }
        policy.forgetUserFront()
        target = RestoreTarget(pid: nil, start: nil)
        return u
    }
    while let line = readLine() {
        guard !line.isEmpty, let data = line.data(using: .utf8),
              let row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
        define(row["procs"])
        if row.keys.contains("input") { input = number(row["input"])?.doubleValue }
        if !started {
            started = true
            let front = pid(row["front"])
            let attach = row["attach"] as? [String: Any]
            lineage = Lineage(tokenEntry: (row["token"] as? String).map(tokenEntry),
                              matcher: attach.map { AttachMatcher(exe: $0["exe"] as? String ?? "", needle: Array(($0["needle"] as? String ?? "").utf8)) })
            for p in (row["before"] as? [NSNumber] ?? []).map({ pid_t($0.int32Value) }) { before[p] = source.start(p) ?? 1 }
            for root in (row["roots"] as? [NSNumber] ?? []).map({ pid_t($0.int32Value) }) {
                lineage.addRoot(root, start: source.start(root) ?? 1)
            }
            if lineage.matcher != nil {
                for p in procs.keys.sorted() { _ = lineage.resolve(p, adopting: true, ancestors: false, source) }
            }
            let frontIsTims = front.map { !inTree($0) } ?? false
            policy = RestorePolicy(userFront: frontIsTims ? front : nil, guardUntil: number(row["guardSeconds"])?.doubleValue ?? 0)
            target = RestoreTarget(pid: frontIsTims ? front : nil, start: front.flatMap(source.start))
            if let front, let window = number(row["frontWindow"])?.intValue {
                _ = target.verified(window, owner: front, ownerStart: source.start(front), ownerInTree: !frontIsTims,
                                    space: number(row["frontWindowSpace"])?.intValue)
            }
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
            if let dropped = revalidate() { out["targetDropped"] = Int(dropped) }
            switch policy.activation(pid: p, inTree: result.inTree, at: t, input: input) {
            case .restore(let to):
                out["decision"] = "restore"
                out["to"] = Int(to)
                out["window"] = target.window(for: to) ?? NSNull()
                spaces.theft(at: t)
            case .restored(let latency):
                out["decision"] = "restored"
                out["latencyMs"] = ms(latency)
                spaces.givenBack(at: t)
            case .user:
                out["decision"] = "user"
                target.userSwitched(to: p, start: source.start(p))
                spaces.timActivated(at: t)
            case .system: out["decision"] = "system"
            case .unrestorable: out["decision"] = "unrestorable"; spaces.theft(at: t)
            case .afterGuard: out["decision"] = "after-guard"
            }
            if let focused = row["focused"] as? [String: Any], let id = number(focused["id"])?.intValue, let owner = pid(focused["pid"]) {
                _ = target.verified(id, owner: owner, ownerStart: source.start(owner), ownerInTree: inTree(owner),
                                    space: number(focused["space"])?.intValue)
            }
            out["target"] = target.window ?? NSNull()
        } else if let p = pid(row["launch"]) {
            out["pid"] = Int(p)
            record(lineage.resolve(p, adopting: true, source))
        } else if let p = pid(row["move"]) {
            out["pid"] = Int(p)
            record(lineage.resolve(p, adopting: false, source))
        } else if let visible = number(row["space"])?.intValue {
            if let window = target.window, row.keys.contains("windowSpace") { target.located(window, space: number(row["windowSpace"])?.intValue) }
            if let dropped = revalidate() { out["targetDropped"] = Int(dropped) }
            switch spaces.observed(visible, at: t, input: input, window: target.window, windowSpace: target.windowSpace) {
            case .unchanged: out["space"] = "unchanged"
            case .user(let space): out["space"] = "user"; out["expected"] = space
            case .restore(let from, let to, let window): out["space"] = "restore"; out["from"] = from; out["to"] = to; out["window"] = window
            case .unrestorable(let from, let to): out["space"] = "unrestorable"; out["from"] = from; out["to"] = to
            case .unexplained(let shown, let expected): out["space"] = "unexplained"; out["from"] = expected; out["to"] = shown
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
    let tree = Tree(Lineage(tokenEntry: token.map(tokenEntry), matcher: matcher), snapshot: liveStarts(), t0: uptime(),
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

func describe(_ reply: Helpers.Reply) -> [String: Any] {
    switch reply {
    case .exited(let code, let data): return ["reply": "exit", "code": Int(code), "out": String(decoding: data, as: UTF8.self)]
    case .timedOut: return ["reply": "timeout"]
    case .refused(let why): return ["reply": "refused", "why": why]
    }
}

/// stdin lines: `call <id> <timeout> <args…>` (a yabai call on a worker queue, tracked as work in flight like a
/// park or a Space check), `main <id> <args…>` (the same call on the main queue), `end` (the guard's end:
/// endWork). stdout: `{"ready": true}`, the events, `{"call": id, "reply": …}` per call (written before the call
/// stops being in flight) and `{"end": {"unsettled", "killed", "problems"}}`. Exits at the end of stdin.
func helpersMode(yabai path: String) -> Never {
    writeLine(["ready": true])
    let calls = DispatchQueue(label: "gui-launch.calls", attributes: .concurrent)
    Thread {
        while let line = readLine() {
            let words = line.split(separator: " ").map(String.init)
            if words.count >= 3, words[0] == "call", let timeout = Double(words[2]) {
                let id = words[1], args = Array(words[3...])
                guard let op = inFlight.begin("call \(id)") else {
                    writeLine(["call": id, "reply": "not started"])
                    continue
                }
                calls.async {
                    writeLine(describe(helpers.run(path, args, timeout: timeout)).merging(["call": id]) { $1 })
                    inFlight.end(op)
                }
            } else if words.count >= 2, words[0] == "main" {
                let id = words[1], args = Array(words[2...])
                DispatchQueue.main.async { writeLine(describe(helpers.run(path, args, timeout: 2)).merging(["call": id]) { $1 }) }
            } else if words == ["end"] {
                inFlight.close()
                let (unsettled, killed) = endWork {}
                writeLine(["end": ["unsettled": unsettled, "killed": killed, "problems": problems.value] as [String: Any]])
            }
        }
        exit(0)
    }.start()
    dispatchMain()
}

// MARK: - Arguments

var argv = Array(CommandLine.arguments.dropFirst())
if argv.first == "--screens" { screens() }
if argv.first == "--decide" { decide() }

var space = 0, guardSeconds = 60.0, adoptTimeout = 30.0
var yabaiPath = "", summaryPath = ""
var mode: String?  // "exec" or "open"
var resolving = false, helperTest = false
var parentWatch: pid_t?
var attachExe: String?, attachNeedle: String?, givenToken: String?
var launchArgv: [String] = []
while !argv.isEmpty {
    let flag = argv.removeFirst()
    if flag == "--" { launchArgv = argv; break }
    if flag == "--exec" || flag == "--open" { mode = String(flag.dropFirst(2)); continue }
    if flag == "--resolve" { resolving = true; continue }
    if flag == "--helpers" { helperTest = true; continue }
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
if helperTest { helpersMode(yabai: yabaiPath) }
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

// MARK: - State

let t0 = uptime()
let workspace = NSWorkspace.shared
let attaching = matcher != nil
let token = UUID().uuidString.lowercased()
let tokenHash = shortHash(token)
let tree = Tree(Lineage(tokenEntry: mode == "open" ? tokenEntry(token) : nil, matcher: matcher), snapshot: liveStarts(),
                t0: t0, tokenHash: tokenHash, needle: attachNeedle)
// The baseline's (main thread): set before anything launches.
var frontAtLaunch: NSRunningApplication?
var focusAtLaunch: [String: Any] = [:]
var timSpaceAtLaunch: Int?
var policy = RestorePolicy(userFront: nil, guardUntil: guardSeconds)  // main thread
let restoreTarget = Locked(RestoreTarget(pid: nil, start: nil))
let spacePolicy = Locked(SpacePolicy(expected: nil))
let spaceEvents = Locked([[String: Any]]())
let moves = Locked([[String: Any]]())
var theft: [String: Any]?          // the tree activation not yet given back (main thread)
let theftPending = Locked(false)   // theft != nil, for the end
var reverted: [[String: Any]] = []  // main thread
/// How the last revert gave focus back, set before its call (the activation it causes may arrive first).
let lastRestore = Locked((method: "", window: Int?.none))
var started = false     // main: launched, or guarding without a launch
var finishing = false   // main
var finished = false    // main
var launchFailure: String?
var launchedAt: Double?
var scanTimer: DispatchSourceTimer?
var spawnedPid: pid_t = 0

let yabaiQueue = DispatchQueue(label: "gui-launch.yabai")
let axQueue = DispatchQueue(label: "gui-launch.ax")
let timQueue = DispatchQueue(label: "gui-launch.tim")
let scanQueue = DispatchQueue(label: "gui-launch.scan")
let restoreQueue = DispatchQueue(label: "gui-launch.restore")
let startQueue = DispatchQueue(label: "gui-launch.start")
let endQueue = DispatchQueue(label: "gui-launch.end")

// MARK: - Tim's input

let anyInputEvent = unsafeBitCast(UInt32.max, to: CGEventType.self)  // kCGAnyInputEventType

/// When Tim's last HID input (keyboard, mouse, trackpad) came, in seconds since launch: the hardware event
/// source's clock (the HIDIdleTime one), so no synthetic event, an app's or yabai's, counts.
func lastInput() -> Double? {
    let since = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInputEvent)
    return since.isFinite && since >= 0 ? uptime() - t0 - since : nil
}

// MARK: - yabai (off the main thread, every call bounded)

let queryTimeout = 2.0
/// A focus on the restore path. While Studio launched, yabai let window queries run past 0.5 s and a query plus
/// a focus took 258 ms (counter-ball receipt 20261006T040054Z): twice the deadline that failed. A focus that
/// misses it falls back to re-activating the app (580 ms there).
let focusTimeout = 1.0

@Sendable func yabaiReply(_ args: [String], timeout: Double = queryTimeout) -> Helpers.Reply {
    helpers.run(yabaiPath, args, timeout: timeout)
}

@Sendable func json(_ data: Data) -> Any? { data.isEmpty ? [:] as [String: Any] : try? JSONSerialization.jsonObject(with: data) }

@Sendable func yabai(_ args: [String], timeout: Double = queryTimeout) -> Any? {
    guard case .exited(0, let data) = yabaiReply(args, timeout: timeout) else { return nil }
    return json(data)
}

@Sendable func windowInfo(_ id: Int) -> [String: Any]? {
    yabai(["query", "--windows", "--window", String(id)]) as? [String: Any]
}

/// The Space shown on Tim's display (the one holding Space 1), from `yabai -m query --spaces`.
@Sendable func timDisplaySpace(_ spaces: Any?) -> Int? {
    guard let spaces = spaces as? [[String: Any]],
          let display = spaces.first(where: { ($0["index"] as? NSNumber)?.intValue == 1 })?["display"] as? NSNumber else { return nil }
    let shown = spaces.first { ($0["display"] as? NSNumber) == display && $0["is-visible"] as? Bool == true }
    return (shown?["index"] as? NSNumber)?.intValue
}

@Sendable func queryTimSpace() -> Int? { timDisplaySpace(yabai(["query", "--spaces"])) }

func windowFields(_ w: [String: Any]?) -> [String: Any] {
    ["window": w?["id"] ?? NSNull(), "windowPid": w?["pid"] ?? NSNull(), "windowApp": w?["app"] ?? NSNull()]
}

// MARK: - Windows (yabaiQueue; the final sweep on endQueue)

/// Moves one tree window to the target Space by id, after checking yabai knows it and that it is the tree's (its
/// pid, with the start time the tree recorded). `seen` is when the event that reported it arrived; yabai may
/// learn of a brand-new window a few ms after Accessibility does, so an unknown id is retried for up to a
/// second, without holding up the queue.
func park(_ id: Int, seen: Double, via: String, final: Bool = false) {
    tracked("park of window \(id) (\(via))", final: final) {
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
}

func sweep(_ via: String, final: Bool = false) {
    tracked("sweep (\(via))", final: final) {
        let seen = uptime()
        guard let windows = yabai(["query", "--windows"]) as? [[String: Any]] else { return }
        for w in windows {
            guard let id = (w["id"] as? NSNumber)?.intValue, let pid = (w["pid"] as? NSNumber)?.int32Value,
                  let at = (w["space"] as? NSNumber)?.intValue, at != 0, at != space, tree.contains(pid) else { continue }
            park(id, seen: seen, via: via, final: final)
        }
    }
}

// MARK: - Accessibility (axQueue; callbacks on axLoop's thread)

@_silgen_name("_AXUIElementGetWindow")
func axWindowID(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

var axLoop: CFRunLoop!
var observers: [pid_t: AXObserver] = [:]  // axQueue

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
        guard observers[pid] == nil, processStart(pid) != nil, !stopping else { return }
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

/// Before every focus or activation for Tim: his restore target's app (`pid`) is still the process it was taken
/// from (pid and start time) and outside the tree (any rule: lineage, token, attach; adopting). If not, the
/// target is dropped and the app is no longer the one focus goes back to. Any thread; no child process.
@Sendable func revalidateTarget(_ pid: pid_t) -> Bool {
    let inTree = tree.adopt(pid, via: "restore-check")
    let start = processStart(pid)
    let ok = restoreTarget.update { $0.pid == pid && $0.revalidate(start: start, inTree: inTree) }
    if !ok {
        emit(["event": "restore-target-dropped", "pid": Int(pid), "reason": inTree ? "in the tree" : "not the process it was taken from"])
        if onMain() {
            if policy.userFront == pid { policy.forgetUserFront() }
        } else {
            DispatchQueue.main.async { if policy.userFront == pid { policy.forgetUserFront() } }
        }
    }
    return ok
}

func activate(_ pid: pid_t) -> Bool {  // main
    guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
    if #available(macOS 14, *) { return app.activate() }
    return app.activate(options: [.activateIgnoringOtherApps])
}

/// Gives focus back to Tim's app `pid`, which a tree process took at `stolenAt` (uptime): focuses his restore-
/// target window by its cached id (no query on this path: a window that is gone fails the focus harmlessly), or,
/// when there is none or the focus fails, re-activates the app (cooperative on macOS 14+: a slow app answers
/// late). The target is checked again first. restoreQueue.
func revert(to pid: pid_t, stolenAt: Double) {
    tracked("revert to pid \(pid)", final: true) {
        let began = uptime()
        var record: [String: Any] = ["event": "restore-call", "to": Int(pid), "method": "none", "window": NSNull(), "ok": false]
        defer {
            record["callMs"] = ms(uptime() - began)
            record["sinceTheftMs"] = ms(uptime() - stolenAt)
            emit(record)
        }
        guard revalidateTarget(pid) else {
            record["reason"] = "the restore target's app joined the tree or exited"
            return
        }
        if let window = restoreTarget.value.window(for: pid) {
            lastRestore.update { $0 = ("window", window) }
            record["window"] = window
            switch yabaiReply(["window", "--focus", String(window)], timeout: focusTimeout) {
            case .exited(0, _):
                record["method"] = "window"
                record["ok"] = true
                return
            case .exited(let code, _): record["windowError"] = "exit \(code)"
            case .timedOut: record["windowError"] = "no answer within \(focusTimeout) s"
            case .refused(let why): record["windowError"] = why
            }
        }
        lastRestore.update { $0 = ("activate", nil) }
        record["method"] = "activate"
        record["ok"] = DispatchQueue.main.sync { activate(pid) }
    }
}

/// After Tim switched to `pid` himself: the window yabai reports focused becomes his restore target, with its
/// Space, once it is that app's (yabai can lag the switch by some ms, so a few tries). timQueue.
func refreshTarget(_ pid: pid_t, attempt: Int = 0) {
    tracked("restore-target refresh for pid \(pid)") {
        guard restoreTarget.value.pid == pid else { return }
        if let w = yabai(["query", "--windows", "--window"]) as? [String: Any],
           let id = (w["id"] as? NSNumber)?.intValue, let owner = (w["pid"] as? NSNumber)?.int32Value {
            let ownerInTree = tree.adopt(owner, via: "restore-target")
            let start = processStart(owner)
            let space = (w["space"] as? NSNumber)?.intValue
            if restoreTarget.update({ $0.verified(id, owner: owner, ownerStart: start, ownerInTree: ownerInTree, space: space) }) {
                emit(["event": "restore-target", "pid": Int(owner), "window": id, "space": space ?? NSNull()])
                return
            }
        }
        if attempt < 5 { timQueue.asyncAfter(deadline: .now() + 0.03) { refreshTarget(pid, attempt: attempt + 1) } }
    }
}

/// Reads the restore-target window's owner and Space again (after a Space restore); a window yabai no longer
/// knows is dropped. timQueue.
@Sendable func verifyTarget(_ id: Int) {
    switch yabaiReply(["query", "--windows", "--window", String(id)]) {
    case .exited(0, let data):
        guard let w = json(data) as? [String: Any], let owner = (w["pid"] as? NSNumber)?.int32Value else { return }
        let ownerInTree = tree.adopt(owner, via: "restore-target")
        let start = processStart(owner)
        let space = (w["space"] as? NSNumber)?.intValue
        _ = restoreTarget.update { $0.window == id && $0.verified(id, owner: owner, ownerStart: start, ownerInTree: ownerInTree, space: space) }
    case .exited:
        restoreTarget.update { $0.located(id, space: nil) }
    case .timedOut, .refused:
        break
    }
}

var spaceReported: (kind: String, space: Int)?  // timQueue: the stray Space last reported, until Tim's display is back
var spacePollScheduled = false                   // timQueue

/// Tim's display, at `t` (seconds since launch) with his last input at `input`: what SpacePolicy decides, done
/// and recorded. timQueue.
func checkSpace(at t: Double, input: Double?) {
    tracked("Space check") {
        guard let visible = queryTimSpace() else { return }
        let target = restoreTarget.value
        let (decision, theftAt) = spacePolicy.update {
            ($0.observed(visible, at: t, input: input, window: target.window, windowSpace: target.windowSpace), $0.theftAt)
        }
        switch decision {
        case .unchanged:
            spaceReported = nil
        case .user(let shown):
            spaceReported = nil
            emit(["event": "user-space", "space": shown, "sinceInputMs": input.map { ms(t - $0) } ?? NSNull()])
        case .restore(let from, let to, let window):
            spaceReported = nil
            restoreSpace(from: from, to: to, window: window, theftAt: theftAt)
        case .unrestorable(let from, let to):
            guard spaceReported?.kind != "unrestorable" || spaceReported?.space != from else { break }
            spaceReported = ("unrestorable", from)
            let record: [String: Any] = ["event": "space-unrestorable", "from": from, "to": to, "expected": to, "window": target.window ?? NSNull()]
            spaceEvents.update { $0.append(record) }
            emit(record)
        case .unexplained(let shown, let expected):
            guard spaceReported?.kind != "unexplained" || spaceReported?.space != shown else { break }
            spaceReported = ("unexplained", shown)
            let record: [String: Any] = ["event": "space-unexplained", "from": expected, "to": shown, "expected": expected,
                                         "sinceInputMs": input.map { ms(t - $0) } ?? NSNull()]
            spaceEvents.update { $0.append(record) }
            emit(record)
        }
    }
}

/// The tree moved Tim's display to `from`: focusing his restore-target window (checked again first) brings `to`,
/// the expected Space, back. Recorded either way: `ok` only when his display shows `to` again.
@Sendable func restoreSpace(from: Int, to: Int, window: Int, theftAt: Double?) {  // timQueue, in a Space check
    var focused = false
    if let pid = restoreTarget.value.pid, revalidateTarget(pid), restoreTarget.value.window == window,
       case .exited(0, _) = yabaiReply(["window", "--focus", String(window)], timeout: focusTimeout) {
        focused = true
    }
    var after = queryTimSpace()
    let until = uptime() + 1
    while after != to && uptime() < until {
        usleep(50_000)
        after = queryTimSpace()
    }
    var record: [String: Any] = ["event": "space-restored", "from": from, "to": after ?? NSNull(), "expected": to,
                                 "window": window, "focused": focused, "ok": after == to]
    record["latencyMs"] = theftAt.map { ms(uptime() - t0 - $0) } ?? NSNull()
    spaceEvents.update { $0.append(record) }
    emit(record)
    verifyTarget(window)
}

/// Checks Tim's Space every 100 ms within the grace of a theft or its return: macOS switches Spaces some ms after
/// an activation, possibly after the revert.
func pollSpace() {  // timQueue
    guard !spacePollScheduled else { return }
    spacePollScheduled = true
    timQueue.asyncAfter(deadline: .now() + 0.1) {
        spacePollScheduled = false
        checkSpace(at: uptime() - t0, input: lastInput())
        if !stopping && spacePolicy.value.polling(at: uptime() - t0) { pollSpace() }
    }
}

// MARK: - Activations (main thread)

/// `t`: uptime when the activation arrived; `input`: Tim's last HID input then (seconds since launch).
func onActivation(_ app: NSRunningApplication, at t: Double, input: Double?) {
    let pid = app.processIdentifier
    let inTree = tree.adopt(pid, via: "activation")
    if let userFront = policy.userFront { _ = revalidateTarget(userFront) }
    let decision = policy.activation(pid: pid, inTree: inTree, at: t - t0, input: input)
    let now = iso()
    let sinceInput: Any = input.map { ms(t - t0 - $0) } ?? NSNull()
    switch decision {
    case .restore(let to):
        if theft == nil {
            theft = ["app": describe(app), "activatedAt": now, "t": t]
            theftPending.update { $0 = true }
        }
        emit(["event": "activation", "app": describe(app), "tree": true, "decision": "restore", "to": Int(to),
              "restoreWindow": restoreTarget.value.window(for: to) ?? NSNull(), "at": now])
        restoreQueue.async { revert(to: to, stolenAt: t) }
        let theftAt = t - t0
        timQueue.async {
            spacePolicy.update { $0.theft(at: theftAt) }
            pollSpace()
        }
        observe(pid)
        yabaiQueue.async { sweep("activation") }
    case .restored(let latency):
        let last = lastRestore.value
        var record: [String: Any] = ["event": "reverted", "to": describe(app), "restoredAt": now, "latencyMs": ms(latency),
                                     "method": last.method, "window": last.window ?? NSNull()]
        if let theft {
            record["stolenBy"] = theft["app"]
            record["activatedAt"] = theft["activatedAt"]
        }
        theft = nil
        theftPending.update { $0 = false }
        reverted.append(record)
        emit(record)
        let at = t - t0
        timQueue.async {
            spacePolicy.update { $0.givenBack(at: at) }
            checkSpace(at: at, input: input)
        }
    case .user:
        if theft != nil { emit(["event": "restore-superseded", "by": describe(app), "at": now]) }
        theft = nil
        theftPending.update { $0 = false }
        let start = processStart(pid)
        restoreTarget.update { $0.userSwitched(to: pid, start: start) }
        let at = t - t0
        timQueue.async {
            spacePolicy.update { $0.timActivated(at: at) }
            refreshTarget(pid)
        }
        emit(["event": "activation", "app": describe(app), "tree": false, "decision": "user", "sinceInputMs": sinceInput, "at": now])
    case .system:
        emit(["event": "activation", "app": describe(app), "tree": false, "decision": "system", "sinceInputMs": sinceInput, "at": now])
    case .unrestorable:
        emit(["event": "activation", "app": describe(app), "tree": true, "decision": "unrestorable", "at": now])
        let theftAt = t - t0
        timQueue.async {
            spacePolicy.update { $0.theft(at: theftAt) }
            pollSpace()
        }
    case .afterGuard:
        break
    }
}

// MARK: - The scan (scanQueue)

func scanOnce() {
    let adopted = tree.scan()
    for pid in adopted { observe(pid) }
    if !adopted.isEmpty { yabaiQueue.async { sweep("attached") } }
}

// MARK: - End

/// Ends the guard (main): no new work starts; on endQueue, work in flight settles (bounded), the final scan and
/// sweep run (unless gui-launch is gone), the helpers still running are killed; then the summary and guard-end.
/// The main thread keeps serving events meanwhile.
func finish(_ reason: String) {  // main
    guard !finishing else { return }
    finishing = true
    inFlight.close()
    scanTimer?.cancel()
    let orphaned = reason == "parent-exited"
    let launched = started
    endQueue.async {
        var focusAtEnd: [String: Any] = [:]
        _ = endWork {
            guard launched && !orphaned else { return }
            // Let a revert issued just now land before the frontmost app is read.
            let landBy = uptime() + 0.2
            while theftPending.value && uptime() < landBy { usleep(5_000) }
            if mode == "open" || attaching { _ = tree.scan() }
            sweep("final", final: true)
            focusAtEnd = windowFields(yabai(["query", "--windows", "--window"]) as? [String: Any])
        }
        DispatchQueue.main.async { conclude(reason, orphaned: orphaned, focusAtEnd: focusAtEnd) }
    }
}

func conclude(_ reason: String, orphaned: Bool, focusAtEnd: [String: Any]) {  // main
    finished = true
    if orphaned { unlink(summaryPath) }  // gui-launch is gone: nobody reads it
    guard started else {
        let message = "the guard ended (\(reason)) before it launched anything"
        complain(message)
        emit(["event": "error", "message": message], last: true)
        exit(2)
    }
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
    if !orphaned {
        var end = focusAtEnd
        end["mainScreen"] = NSScreen.main?.localizedName ?? NSNull()
        var summary = tree.summary
        summary.merge([
            "space": space, "guardSeconds": guardSeconds, "endReason": reason, "error": launchFailure ?? NSNull(),
            "fault": fault ?? NSNull(), "token": tokenHash,
            "frontAtLaunch": describe(frontAtLaunch), "frontAtEnd": describe(workspace.frontmostApplication),
            "userFront": describe(policy.userFront.flatMap { NSRunningApplication(processIdentifier: $0) }),
            "restorePending": theft != nil, "focusAtLaunch": focusAtLaunch, "focusAtEnd": end,
            "timSpace": ["atLaunch": timSpaceAtLaunch ?? NSNull(), "expected": spacePolicy.value.expected ?? NSNull()] as [String: Any],
            "reverted": reverted, "moves": moves.value, "spaceRestores": spaceEvents.value, "problems": problems.value,
        ]) { _, new in new }
        let data = try! JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys, .withoutEscapingSlashes])
        FileManager.default.createFile(atPath: summaryPath, contents: data)
    }
    emit(["event": "guard-end", "reason": reason, "seconds": decimal(uptime() - t0, 3), "reverted": reverted.count,
          "moved": moves.value.filter { $0["moved"] as? Bool == true }.count], last: true)
    if let launchFailure {
        complain(launchFailure)
        exit(2)
    }
    exit(0)
}

// MARK: - Start

// From here the main thread serves SIGTERM/SIGINT and gui-launch's exit, and never waits on a child process.
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

// The guard is up: a caller may watch or signal it (it runs as the caller's user, in sudo's process group).
emit(["event": "guard", "pid": Int(getpid()), "pgid": Int(getpgrp()), "start": processStart(getpid()).map { NSNumber(value: $0) } ?? NSNull()])

let axReady = DispatchSemaphore(value: 0)
Thread {
    axLoop = CFRunLoopGetCurrent()
    let keepAlive = CFRunLoopTimerCreateWithHandler(nil, .greatestFiniteMagnitude, 0, 0, 0) { _ in }
    CFRunLoopAddTimer(axLoop, keepAlive, .defaultMode)
    axReady.signal()
    CFRunLoopRun()
}.start()
axReady.wait()

/// Runs `work` on startQueue while the main thread keeps serving its queue. nil: the guard began to end.
func awaitOffMain<T>(_ work: @escaping () -> T) -> T? {
    let result = Locked<T?>(nil)
    startQueue.async {
        let value = work()
        result.update { $0 = value }
        DispatchQueue.main.async {}  // wakes the loop below
    }
    while !finishing {
        if let value = result.value { return value }
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    return nil
}

struct Baseline {
    var adopted: [pid_t] = []
    var frontIsTims = false
    var focused: [String: Any] = windowFields(nil)
    var target = RestoreTarget(pid: nil, start: nil)
    var timSpace: Int?
    var error: String?
}

/// Before anything launches (startQueue): attach members already running join the tree; then Tim's front app
/// (outside the tree), his focused window and its Space (the restore target, if it is that app's and outside the
/// tree), and the Space his display shows. A yabai call that fails or misses its deadline is an error.
func takeBaseline(front: NSRunningApplication?) -> Baseline {
    var b = Baseline()
    tracked("the baseline", final: true) {
        if attaching { b.adopted = tree.scan() }
        if let front {
            let pid = front.processIdentifier
            let start = processStart(pid)
            b.frontIsTims = start != nil && !tree.adopt(pid, via: "baseline")
            if b.frontIsTims { b.target = RestoreTarget(pid: pid, start: start) }
        }
        switch yabaiReply(["query", "--windows", "--window"]) {
        case .exited(0, let data):
            guard let w = json(data) as? [String: Any] else { b.error = "yabai's focused window is unreadable"; return }
            b.focused = windowFields(w)
            if let id = (w["id"] as? NSNumber)?.intValue, let owner = (w["pid"] as? NSNumber)?.int32Value {
                _ = b.target.verified(id, owner: owner, ownerStart: processStart(owner), ownerInTree: tree.adopt(owner, via: "baseline"),
                                      space: (w["space"] as? NSNumber)?.intValue)
            }
        case .exited:
            break  // no window has focus
        case .timedOut:
            b.error = "yabai -m query --windows --window did not answer within \(queryTimeout) s"
            return
        case .refused(let why):
            b.error = why
            return
        }
        switch yabaiReply(["query", "--spaces"]) {
        case .exited(0, let data):
            b.timSpace = timDisplaySpace(json(data))
            if b.timSpace == nil { b.error = "yabai shows no Space on Tim's display" }
        case .exited(let code, _): b.error = "yabai -m query --spaces exited \(code)"
        case .timedOut: b.error = "yabai -m query --spaces did not answer within \(queryTimeout) s"
        case .refused(let why): b.error = why
        }
    }
    return b
}

let launchFront = workspace.frontmostApplication
guard let baseline = awaitOffMain({ takeBaseline(front: launchFront) }) else { dispatchMain() }
if let error = baseline.error { fail("no baseline, so nothing was launched: \(error)") }
frontAtLaunch = launchFront
focusAtLaunch = baseline.focused
focusAtLaunch["mainScreen"] = NSScreen.main?.localizedName ?? NSNull()
timSpaceAtLaunch = baseline.timSpace
policy = RestorePolicy(userFront: baseline.frontIsTims ? launchFront?.processIdentifier : nil, guardUntil: guardSeconds)
restoreTarget.update { $0 = baseline.target }
spacePolicy.update { $0 = SpacePolicy(expected: baseline.timSpace) }

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

let center = workspace.notificationCenter
center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil) { note in
    let t = uptime()
    let input = lastInput()
    guard !finished, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
    onActivation(app, at: t, input: input)
}
center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: nil) { note in
    guard !finished, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
    if tree.adopt(app.processIdentifier, via: "launch") { observe(app.processIdentifier) }
}
center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: nil) { _ in
    let t = uptime() - t0
    let input = lastInput()
    yabaiQueue.async { sweep("space-change") }
    timQueue.async { checkSpace(at: t, input: input) }
}
center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: nil) { _ in
    if mode != nil && !attaching && tree.hasRoots && !tree.anyAlive { finish("tree-exited") }
}
let appsObservation = workspace.observe(\.runningApplications, options: [.new]) { _, change in
    for app in change.newValue ?? [] where tree.adopt(app.processIdentifier, via: "launch") { observe(app.processIdentifier) }
}

for pid in baseline.adopted { observe(pid) }
if !baseline.adopted.isEmpty { yabaiQueue.async { sweep("attached") } }
if mode == "open" || attaching {
    let timer = DispatchSource.makeTimerSource(queue: scanQueue)
    timer.schedule(deadline: .now(), repeating: .milliseconds(150), leeway: .milliseconds(20))
    timer.setEventHandler { if !stopping { scanOnce() } }
    timer.resume()
    scanTimer = timer
}

// MARK: - Launch

// A signal or gui-launch's exit that arrived during the startup ends the guard before anything launches.
RunLoop.main.run(mode: .default, before: Date())
if finishing { dispatchMain() }

let attachRecord: Any = matcher.map { ["exe": $0.exe, "needle": attachNeedle ?? ""] as [String: Any] } ?? NSNull()
let startRecord: [String: Any] = [
    "space": space, "guardSeconds": guardSeconds, "front": describe(frontAtLaunch), "focus": focusAtLaunch,
    "timSpace": timSpaceAtLaunch ?? NSNull(), "restoreWindow": baseline.target.window ?? NSNull(),
    "restoreWindowSpace": baseline.target.windowSpace ?? NSNull(), "attach": attachRecord,
]
if launchArgv.isEmpty {
    started = true
    emit(startRecord.merging(["event": "guarding"]) { $1 })
} else {
    let entry = "GUI_LAUNCH_TOKEN=\(token)"
    var spawnArgv = launchArgv
    var environment = ProcessInfo.processInfo.environment.filter { $0.key != "GUI_LAUNCH_TOKEN" }.map { "\($0.key)=\($0.value)" }
    if mode == "open" { spawnArgv.insert(contentsOf: ["--env", entry], at: 1) } else { environment.append(entry) }
    var fileActions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&fileActions)
    posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addinherit_np(&fileActions, 2)
    posix_spawn_file_actions_adddup2(&fileActions, 2, 1)  // stdout carries only our events
    // Its own process group (a Ctrl-C on gui-launch spares the app), the signals the guard ignores at their
    // defaults, and no descriptor but these three (none of a yabai helper's pipes, which would hold it open).
    var attributes = childAttributes(onlyListedFds: true)
    let cArgs = spawnArgv.map { strdup($0) } + [nil]
    let cEnv = environment.map { strdup($0) } + [nil]
    let spawned = posix_spawnp(&spawnedPid, spawnArgv[0], &fileActions, &attributes, cArgs, cEnv)
    guard spawned == 0 else { fail("cannot run \(spawnArgv[0]): \(String(cString: strerror(spawned)))") }
    started = true
    launchedAt = uptime()
    if mode == "exec" {
        tree.addRoot(spawnedPid)
        observe(spawnedPid)
    }
    emit(startRecord.merging([
        "event": "launched", "argv": spawnArgv.map { $0 == entry ? "GUI_LAUNCH_TOKEN=<sha256 \(tokenHash)>" : $0 },
        "pid": Int(spawnedPid), "token": tokenHash,
    ]) { $1 })
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
            scanQueue.async { if !stopping { scanOnce() } }
        }
    }
    if mode == "open" {
        DispatchQueue.main.asyncAfter(deadline: .now() + adoptTimeout) { if !tree.hasRoots { finish("no-launch") } }
    }
}

Timer.scheduledTimer(withTimeInterval: guardSeconds, repeats: false) { _ in finish("timeout") }
RunLoop.main.run()
