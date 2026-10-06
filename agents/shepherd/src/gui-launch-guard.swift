// gui-launch-guard: the event-driven half of bin/gui-launch (its docstring is the user documentation).
//
// Spawns the launch argv gui-launch built (`open -g …`, or an executable), then until the guard ends:
//   - reverts activations: when a process of the launched tree becomes frontmost (NSWorkspace
//     didActivateApplicationNotification), it re-activates the app the user had frontmost before;
//   - parks windows: each tree window that Accessibility reports created or focused, and each tree window
//     yabai lists when the tree activates or the active Space changes, is moved by id to --space.
// The guard ends after --guard-seconds, when the whole tree has exited, or on SIGTERM/SIGINT; it never
// quits what it launched. Events go to stdout as JSON lines; the summary gui-launch checks goes to --summary.
// Threads: main handles workspace notifications and restores, so a slow app or yabai never delays a
// restore; Accessibility calls run on axQueue (observer callbacks on their own run loop thread) and
// yabai calls on yabaiQueue.
//
// usage: gui-launch-guard --space N --guard-seconds S --yabai PATH --summary PATH
//            (--exec | --app-path P | --app-name N | --bundle-id B) -- <argv to spawn>
//        gui-launch-guard --screens   screen name -> CGDirectDisplayID (yabai's display "id"), as JSON
//        gui-launch-guard --decide    restore decisions for synthetic activations on stdin (tests)
// build: swiftc -O -swift-version 5 -target arm64-apple-macos13 \
//          -o ~/.local/bin/gui-launch-guard src/gui-launch-guard.swift
import AppKit
import ApplicationServices

// MARK: - Restore decision (pure; --decide feeds it synthetic activations)

/// What to do when an app becomes frontmost. `userFront` is the app to give focus back to: the
/// frontmost app at launch, then whichever app outside the tree last became frontmost (the user's choice).
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

func emit(_ event: [String: Any]) {
    var record = event
    if record["at"] == nil { record["at"] = iso() }
    guard var data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
    data.append(10)
    outLock.lock()
    data.withUnsafeBytes { _ = write(1, $0.baseAddress, $0.count) }
    outLock.unlock()
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("gui-launch-guard: " + message + "\n").data(using: .utf8)!)
    exit(2)
}

func describe(_ app: NSRunningApplication?) -> Any {
    guard let app else { return NSNull() }
    return ["pid": Int(app.processIdentifier), "name": app.localizedName ?? "", "bundle": app.bundleIdentifier ?? ""]
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

/// stdin: `{"front": <pid or null>, "guardSeconds": S}`, then one `{"t": <s since launch>, "pid": P, "tree": bool}`
/// per activation. stdout: one decision per activation.
func decide() -> Never {
    var policy: RestorePolicy?
    while let line = readLine() {
        guard let data = line.data(using: .utf8), !line.isEmpty,
              let row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
        guard var current = policy else {
            policy = RestorePolicy(userFront: (row["front"] as? NSNumber).map { pid_t($0.int32Value) },
                                   guardUntil: (row["guardSeconds"] as? NSNumber)?.doubleValue ?? 0)
            continue
        }
        let pid = pid_t((row["pid"] as? NSNumber)?.int32Value ?? 0)
        let t = (row["t"] as? NSNumber)?.doubleValue ?? 0
        var out: [String: Any] = ["t": t, "pid": Int(pid)]
        switch current.activation(pid: pid, inTree: row["tree"] as? Bool ?? false, at: t) {
        case .restore(let to): out["decision"] = "restore"; out["to"] = Int(to)
        case .restored(let latency): out["decision"] = "restored"; out["latencyMs"] = ms(latency)
        case .user: out["decision"] = "user"
        case .unrestorable: out["decision"] = "unrestorable"
        case .afterGuard: out["decision"] = "after-guard"
        }
        policy = current
        let json = try! JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
        print(String(data: json, encoding: .utf8)!)
    }
    exit(0)
}

// MARK: - Arguments

enum Target {
    case exec
    case appPath(String)
    case appName(String)
    case bundleID(String)
}

var argv = Array(CommandLine.arguments.dropFirst())
if argv.first == "--screens" { screens() }
if argv.first == "--decide" { decide() }

var space = 0, guardSeconds = 60.0
var yabaiPath = "", summaryPath = ""
var target: Target?
var launchArgv: [String] = []
while !argv.isEmpty {
    let flag = argv.removeFirst()
    if flag == "--" { launchArgv = argv; break }
    if flag == "--exec" { target = .exec; continue }
    guard !argv.isEmpty else { fail("\(flag) needs a value") }
    let value = argv.removeFirst()
    switch flag {
    case "--space": space = Int(value) ?? 0
    case "--guard-seconds": guardSeconds = Double(value) ?? -1
    case "--yabai": yabaiPath = value
    case "--summary": summaryPath = value
    case "--app-path": target = .appPath(URL(fileURLWithPath: value).resolvingSymlinksInPath().standardizedFileURL.path)
    case "--app-name": target = .appName(value)
    case "--bundle-id": target = .bundleID(value)
    default: fail("unknown flag \(flag)")
    }
}
guard space > 0, guardSeconds > 0, !yabaiPath.isEmpty, !summaryPath.isEmpty, let target, !launchArgv.isEmpty else {
    fail("usage: --space N --guard-seconds S --yabai PATH --summary PATH (--exec | --app-path P | --app-name N | --bundle-id B) -- argv")
}
// Parking windows needs Accessibility events; without them a window could sit on Tim's Space unseen.
guard AXIsProcessTrusted() else {
    fail("this process is not trusted for Accessibility, so it cannot see new windows: run it from a terminal app " +
         "listed in System Settings > Privacy & Security > Accessibility")
}

// MARK: - The launched process tree

func parent(of pid: pid_t) -> pid_t {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return 0 }
    return info.kp_eproc.e_ppid
}

func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

/// Roots are the spawned executable (--exec), or each app that matches the open target, was not running
/// before the launch and appeared before `open` returned (plus a second of grace): a later instance is
/// someone else's, e.g. Tim opening Studio himself. Members are roots and their descendants, remembered once
/// seen, so a child still counts after its root exits (Minecraft's java after Prism quits).
final class Tree {
    private let lock = NSLock()
    private let target: Target
    private let before: Set<pid_t>
    private var adoptUntil = Double.infinity
    private var rootSet = Set<pid_t>()
    private var members = Set<pid_t>()

    init(target: Target, before: Set<pid_t>) {
        self.target = target
        self.before = before
    }

    func addRoot(_ pid: pid_t) {
        lock.lock(); defer { lock.unlock() }
        rootSet.insert(pid)
        members.insert(pid)
    }

    /// `open` has returned: new matching apps from now on are not this launch's.
    func launchReturned() {
        lock.lock(); defer { lock.unlock() }
        adoptUntil = uptime() + 1
    }

    private func isRoot(_ pid: pid_t) -> Bool {
        if rootSet.contains(pid) { return true }
        if before.contains(pid) || uptime() > adoptUntil { return false }
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        let matches: Bool
        switch target {
        case .exec: matches = false
        case .appPath(let path): matches = app.bundleURL?.resolvingSymlinksInPath().standardizedFileURL.path == path
        case .appName(let name):
            matches = app.bundleURL?.deletingPathExtension().lastPathComponent == name || app.localizedName == name
        case .bundleID(let id): matches = app.bundleIdentifier == id
        }
        if matches {
            rootSet.insert(pid)
            emit(["event": "root", "app": describe(app)])
        }
        return matches
    }

    func contains(_ pid: pid_t) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var chain: [pid_t] = []
        var p = pid
        while p > 1 {
            if members.contains(p) || isRoot(p) {
                members.insert(p)
                members.formUnion(chain)
                return true
            }
            chain.append(p)
            p = parent(of: p)
        }
        return false
    }

    var roots: Set<pid_t> {
        lock.lock(); defer { lock.unlock() }
        return rootSet
    }

    var known: Set<pid_t> {
        lock.lock(); defer { lock.unlock() }
        return members
    }

    var anyAlive: Bool { known.contains(where: alive) }
}

// MARK: - State

let t0 = uptime()
let workspace = NSWorkspace.shared
let frontAtLaunch = workspace.frontmostApplication
let tree = Tree(target: target, before: Set(workspace.runningApplications.map(\.processIdentifier)))
var policy = RestorePolicy(userFront: frontAtLaunch?.processIdentifier, guardUntil: guardSeconds)
var theft: [String: Any]?          // the tree activation not yet given back (main thread)
var reverted: [[String: Any]] = []  // main thread
var moves: [[String: Any]] = []     // yabaiQueue
var finished = false
var launchFailure: String?
/// Where focus sat at launch, for gui-launch's check: yabai's focused window, and the screen AppKit calls main
/// (the key window's). A restored app can leave the active display on the thief's screen (yabai still reports it
/// after Superwhisper got focus back, 2026-10-06); the check reports that rather than move Tim's windows.
let focusAtLaunch = focusContext()

let yabaiQueue = DispatchQueue(label: "gui-launch.yabai")
let axQueue = DispatchQueue(label: "gui-launch.ax")
let timSpaces: Set<Int> = [1, 2, 3, 4]

// MARK: - Windows (yabaiQueue)

@Sendable func yabai(_ args: [String]) -> Any? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: yabaiPath)
    process.arguments = ["-m"] + args
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return data.isEmpty ? [:] as [String: Any] : try? JSONSerialization.jsonObject(with: data)
}

@Sendable func windowInfo(_ id: Int) -> [String: Any]? {
    yabai(["query", "--windows", "--window", String(id)]) as? [String: Any]
}

/// yabai's focused window (a query; yabai acts on a window only when given its id) and AppKit's main screen.
@Sendable func focusContext() -> [String: Any] {
    let w = yabai(["query", "--windows", "--window"]) as? [String: Any]
    return ["window": w?["id"] ?? NSNull(), "windowPid": w?["pid"] ?? NSNull(), "windowApp": w?["app"] ?? NSNull(),
            "mainScreen": NSScreen.main?.localizedName ?? NSNull()]
}

/// Moves one tree window to the target Space by id, after checking yabai knows it and that it is ours.
/// `seen` is when the event that reported it arrived; yabai may learn of a brand-new window a few ms
/// after Accessibility does, so an unknown id is retried for up to a second.
func park(_ id: Int, seen: Double, via: String) {
    var info = windowInfo(id)
    while info == nil && uptime() - seen < 1 {
        usleep(5_000)
        info = windowInfo(id)
    }
    guard let w = info, let pid = (w["pid"] as? NSNumber)?.int32Value, tree.contains(pid),
          let from = (w["space"] as? NSNumber)?.intValue, from != 0, from != space else { return }
    _ = yabai(["window", String(id), "--space", String(space)])
    let after = (windowInfo(id)?["space"] as? NSNumber)?.intValue
    let done = uptime()
    var record: [String: Any] = [
        "event": "window", "id": id, "pid": Int(pid), "app": w["app"] ?? "", "title": w["title"] ?? "",
        "subrole": w["subrole"] ?? "", "from": from, "to": after ?? NSNull(), "moved": after == space, "via": via,
        "latencyMs": ms(done - seen),
    ]
    if timSpaces.contains(from) { record["onTimSpaceMs"] = ms(done - seen) }
    moves.append(record)
    emit(record)
}

func sweep(_ via: String) {
    let seen = uptime()
    guard let windows = yabai(["query", "--windows"]) as? [[String: Any]] else { return }
    for w in windows {
        guard let id = (w["id"] as? NSNumber)?.intValue, let pid = (w["pid"] as? NSNumber)?.int32Value,
              let at = (w["space"] as? NSNumber)?.intValue, at != 0, at != space, tree.contains(pid) else { continue }
        park(id, seen: seen, via: via)
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

/// Subscribes to a tree app's window events. A just-launched app answers Accessibility only once its run
/// loop is up, so a refused subscription is retried every 20 ms until the guard ends.
func observe(_ pid: pid_t) {
    axQueue.async {
        guard observers[pid] == nil, alive(pid), !finished else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var created: AXObserver?
        guard AXObserverCreate(pid, axCallback, &created) == .success, let observer = created,
              AXObserverAddNotification(observer, app, kAXWindowCreatedNotification as CFString, nil) == .success else {
            axQueue.asyncAfter(deadline: .now() + 0.02) { observe(pid) }
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

// MARK: - Activations (main thread)

/// Re-activates the app Tim had frontmost: the app only, never one of his windows by id.
@Sendable func restore(_ pid: pid_t) -> Bool {
    guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
    if #available(macOS 14, *) { return app.activate() }
    return app.activate(options: [.activateIgnoringOtherApps])
}

func onActivation(_ app: NSRunningApplication, at t: Double) {
    let pid = app.processIdentifier
    let inTree = tree.contains(pid)
    let decision = policy.activation(pid: pid, inTree: inTree, at: t - t0)
    let now = iso()
    switch decision {
    case .restore(let to):
        let ok = restore(to)
        let called = uptime()
        if theft == nil { theft = ["app": describe(app), "activatedAt": now, "t": t] }
        emit(["event": "activation", "app": describe(app), "tree": true, "decision": "restore", "to": Int(to),
              "restoreCallOk": ok, "restoreCallMs": ms(called - t), "at": now])
        observe(pid)
        yabaiQueue.async { sweep("activation") }
    case .restored(let latency):
        var record: [String: Any] = ["event": "reverted", "to": describe(app), "restoredAt": now, "latencyMs": ms(latency)]
        if let theft {
            record["stolenBy"] = theft["app"]
            record["activatedAt"] = theft["activatedAt"]
        }
        theft = nil
        reverted.append(record)
        emit(record)
    case .user:
        if theft != nil { emit(["event": "restore-superseded", "by": describe(app), "at": now]) }
        theft = nil
        emit(["event": "activation", "app": describe(app), "tree": false, "decision": "user", "at": now])
    case .unrestorable:
        emit(["event": "activation", "app": describe(app), "tree": true, "decision": "unrestorable", "at": now])
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
center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: nil) { _ in
    yabaiQueue.async { sweep("space-change") }
}
center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: nil) { _ in
    if !tree.roots.isEmpty && !tree.anyAlive { finish("tree-exited") }
}
let appsObservation = workspace.observe(\.runningApplications, options: [.new]) { _, change in
    for app in change.newValue ?? [] where tree.contains(app.processIdentifier) { observe(app.processIdentifier) }
}

// MARK: - End

var finishing = false
func finish(_ reason: String) {
    guard !finishing else { return }
    finishing = true
    yabaiQueue.sync { sweep("final") }
    // Let a restore issued just now land before reading the frontmost app.
    let wait = Date().addingTimeInterval(0.5)
    while theft != nil && Date() < wait { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    finished = true
    var reason = reason
    if launchFailure == nil && tree.roots.isEmpty { launchFailure = "no new process of the launch target appeared" }
    if let launchFailure { reason = "error" ; emit(["event": "error", "message": launchFailure]) }
    let focusAtEnd = focusContext()
    let summary: [String: Any] = yabaiQueue.sync {
        [
            "space": space, "guardSeconds": guardSeconds, "endReason": reason, "error": launchFailure ?? NSNull(),
            "frontAtLaunch": describe(frontAtLaunch), "frontAtEnd": describe(workspace.frontmostApplication),
            "userFront": describe(policy.userFront.flatMap { NSRunningApplication(processIdentifier: $0) }),
            "restorePending": theft != nil, "focusAtLaunch": focusAtLaunch, "focusAtEnd": focusAtEnd,
            "roots": tree.roots.sorted().map(Int.init), "tree": tree.known.sorted().map(Int.init),
            "reverted": reverted, "moves": moves,
        ]
    }
    let data = try! JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys, .withoutEscapingSlashes])
    FileManager.default.createFile(atPath: summaryPath, contents: data)
    emit(["event": "guard-end", "reason": reason, "seconds": decimal(uptime() - t0, 3), "reverted": reverted.count,
          "moved": moves.filter { $0["moved"] as? Bool == true }.count])
    if let launchFailure { fail(launchFailure) }
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

// MARK: - Launch

var spawnedPid: pid_t = 0
var fileActions: posix_spawn_file_actions_t?
posix_spawn_file_actions_init(&fileActions)
posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
posix_spawn_file_actions_adddup2(&fileActions, 2, 1)  // stdout carries only our events
var attributes: posix_spawnattr_t?
posix_spawnattr_init(&attributes)
posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))  // a Ctrl-C on gui-launch spares the app
posix_spawnattr_setpgroup(&attributes, 0)
let cArgs = launchArgv.map { strdup($0) } + [nil]
let spawned = posix_spawnp(&spawnedPid, launchArgv[0], &fileActions, &attributes, cArgs, environ)
guard spawned == 0 else { fail("cannot run \(launchArgv[0]): \(String(cString: strerror(spawned)))") }
emit(["event": "launched", "argv": launchArgv, "pid": Int(spawnedPid), "space": space, "guardSeconds": guardSeconds,
      "front": describe(frontAtLaunch), "focus": focusAtLaunch])

if case .exec = target {
    tree.addRoot(spawnedPid)
    observe(spawnedPid)
}
// Reap the spawned process on its own thread (a dispatch exit source can miss a fast `open`).
DispatchQueue.global().async {
    var status: Int32 = 0
    while waitpid(spawnedPid, &status, 0) == -1 && errno == EINTR {}
    DispatchQueue.main.async {
        if case .exec = target {
            if !tree.anyAlive { finish("tree-exited") }
            return
        }
        // `open` has returned: the app is launched, or open failed.
        tree.launchReturned()
        let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        if code != 0 {
            launchFailure = "open exited \(code)"
            finish("error")
        }
        for app in workspace.runningApplications where tree.contains(app.processIdentifier) { observe(app.processIdentifier) }
    }
}

Timer.scheduledTimer(withTimeInterval: guardSeconds, repeats: false) { _ in finish("timeout") }
RunLoop.main.run()
