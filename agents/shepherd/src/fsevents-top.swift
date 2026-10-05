// fsevents-top: count what fseventsd actually receives, grouped by path prefix.
//
// fs_usage counts every filesystem syscall (reads and stats included), which is
// not what fseventsd processes. This subscribes to the same FSEvents stream the
// daemon serves, so counts are mutations only: create, modify, remove, rename.
//
// usage: fsevents-top [seconds=30] [depth=5] [rows=25]
// build: swiftc -O -swift-version 5 -target arm64-apple-macos13 \
//          -o ~/.local/bin/fsevents-top ~/.local/src/fsevents-top.swift
import CoreServices
import Foundation

let argv = CommandLine.arguments
let seconds = argv.count > 1 ? Double(argv[1]) ?? 30 : 30
let depth = argv.count > 2 ? Int(argv[2]) ?? 5 : 5
let rows = argv.count > 3 ? Int(argv[3]) ?? 25 : 25
let home = NSHomeDirectory()

var total = 0
var events: [String: Int] = [:]
var uniquePaths: [String: Set<String>] = [:]
var allPaths = Set<String>()
var created = 0, removed = 0, renamed = 0, modified = 0, dropped = 0

func group(_ path: String) -> String {
    var p = path
    if p.hasPrefix("/System/Volumes/Data/") { p = String(p.dropFirst("/System/Volumes/Data".count)) }
    if p.hasPrefix(home) { p = "~" + p.dropFirst(home.count) }
    let parts = p.split(separator: "/", omittingEmptySubsequences: true)
    let keep = parts.prefix(depth).joined(separator: "/")
    return p.hasPrefix("~") ? keep : "/" + keep
}

let callback: FSEventStreamCallback = { _, _, count, pathsPtr, flagsPtr, _ in
    let paths = unsafeBitCast(pathsPtr, to: NSArray.self)
    for i in 0..<count {
        guard let path = paths[i] as? String else { continue }
        let f = Int(flagsPtr[i])
        if f & kFSEventStreamEventFlagUserDropped != 0 || f & kFSEventStreamEventFlagKernelDropped != 0 {
            dropped += 1
            continue
        }
        total += 1
        if f & kFSEventStreamEventFlagItemCreated != 0 { created += 1 }
        if f & kFSEventStreamEventFlagItemRemoved != 0 { removed += 1 }
        if f & kFSEventStreamEventFlagItemRenamed != 0 { renamed += 1 }
        if f & kFSEventStreamEventFlagItemModified != 0 { modified += 1 }
        let g = group(path)
        events[g, default: 0] += 1
        uniquePaths[g, default: []].insert(path)
        allPaths.insert(path)
    }
}

let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
guard let stream = FSEventStreamCreate(nil, callback, nil, ["/"] as CFArray,
                                       FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2, flags) else {
    FileHandle.standardError.write("FSEventStreamCreate failed\n".data(using: .utf8)!)
    exit(1)
}
let queue = DispatchQueue(label: "fsevents-top")
FSEventStreamSetDispatchQueue(stream, queue)
FSEventStreamStart(stream)
Thread.sleep(forTimeInterval: seconds)
FSEventStreamStop(stream)
FSEventStreamInvalidate(stream)
FSEventStreamRelease(stream)

queue.sync {
    let rate = Double(total) / seconds
    print(String(format: "window %.0fs: %d events (%.0f/s), %d unique paths, dropped=%d", seconds, total, rate, allPaths.count, dropped))
    print("  created=\(created) removed=\(removed) renamed=\(renamed) modified=\(modified)")
    print(String(format: "  %8@ %6@ %8@  %@", "events", "share", "uniq", "prefix (depth \(depth))"))
    for (g, n) in events.sorted(by: { $0.value > $1.value }).prefix(rows) {
        let share = total > 0 ? 100.0 * Double(n) / Double(total) : 0
        print(String(format: "  %8d %5.1f%% %8d  %@", n, share, uniquePaths[g]?.count ?? 0, g))
    }
}
