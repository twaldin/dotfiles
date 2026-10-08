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
// restore target, if the window is that app's and the app is outside the tree), the Space his display shows, and
// yabai's Spaces by SkyLight id. A yabai call there that fails, misses its deadline or answers unreadably (a window
// row that does not say whether it has focus, a focused row without its id, pid or Space, a Space without its id
// and index) is an error (exit 2): nothing launches; so is a direct read of his display (below) that fails or does
// not show the Space yabai says it shows, and an AppKit app (Threads, below) that is not of the guard's own class or
// whose policy will not be .prohibited.
// Until the guard ends it
//   - attributes: a theft window runs from a tree activation until focus is back with Tim's app (or, with no app
//     to give it back to, with any app outside the tree) and 2 s after. Inside it no activation and no Space
//     change is Tim's, but for his takeover; outside it every activation outside the tree and every Space change
//     is. His takeover (GR2, bench's addendum 3; until it, his HID input was only logged, never used as authority):
//     an app outside the tree, other than the one focus goes back to, that becomes frontmost within 100 ms of his
//     last HID input (sinceInputMs) is his choice (decision user, takeover), in a theft or grace window too: it is
//     never reverted, it ends an open theft (whose revert is then no longer wanted) and becomes the app focus goes
//     back to, and each Space his display shows from then until the next tree activation is his (but one that stays
//     on the Space the tree took him to), never a breach, and no theft before it revokes it; so is a Space
//     notification whose interval (since the notification before it) began at or after it: judged as outside a
//     theft window, never charged to a theft before it. Later takeovers keep that first cutoff until a tree
//     activation resets it. 100 ms: in the
//     after-dark receipt (e8790f2c) each of his 12 activations came 2.7-47 ms after his input, in the tab receipt
//     (542d177d) 0.3 and 38.6 ms; it is about twice the slowest. A tree app's activation is never his. The
//     residual risk: the HID table counts any input, a mouse move or a keystroke too, and a process can feed it (the
//     tree's too: synthetic input), so an app macOS activates in a tree's theft cascade within 100 ms of such input
//     is taken for his, with the Spaces his display shows until the tree next activates: unreverted, no breach, and
//     the check passes. Conversely, should his activation reach the guard after the Space change it causes, that
//     change is still the tree's (a breach). Input never decides a Space change on its own;
//   - reverts activations: when a tree process becomes frontmost before shutdown begins, it re-activates Tim's app at
//     once, in the turn that decides the activation (GR2: it never waits for yabai), after the checks the fallback's
//     final turn makes (below); then, unless focus is back by then, it focuses his restore-target window by id, or re-activates his
//     app again when there is none or the focus fails. An app activation cannot hand focus to another process: the
//     app is checked by pid and start time in the turn that activates it; a window id can pass to another process
//     unseen, so only a window is vouched for. The target is his focused window at launch
//     or after an app switch of his own, never a tree member's window. Before the focus, his app is checked again
//     (the same process, by pid and start time, outside the tree, still the one focus goes back to, the theft
//     still open), and so is the window's owner, by a query made for that focus: its answer counts only if no
//     activation, Space change or change of the restore target came while it ran (else it is asked again, within
//     the focus's 1 s, while the focus is still wanted). A window that cannot be vouched for is not focused, and
//     the focus still has to be wanted immediately before it is made (once focus is back, it is not). The fallback
//     activation checks the app again in the same main-queue turn that activates it. An owner query that runs out
//     of time is an expected-slow event, and no problem, only when the window was not focused, an activation (at
//     once, or the fallback) ran and succeeded, and a read after the revert shows the app it fronted (his, or a system
//     modal in its place) frontmost and his display on the expected Space. GR2 item 6 (live finding, roblox's runs 1
//     and 3): nothing is ever fronted over a system modal on screen (WindowServer owner SecurityAgent; [INFERENCE]
//     coreautha, UserNotificationCenter, universalAccessAuthWarn): no window is focused over it, and in place of his
//     app the modal's process is re-fronted (method modal; its activation gives focus back). Windows on screen that
//     cannot be read cannot rule a modal out (review 3): no app is activated and no window focused for him then, a
//     problem. The guard focuses no display (review 3): `yabai -m display --focus` focuses and raises a window of
//     yabai's choosing (on an empty display it can click), which could front another app over a modal. When no window
//     of his was focused (none at launch, or none vouched for), or there is no app to give focus back to
//     (unrestorable; display-check), it checks instead: a modal on screen is re-fronted, whichever display has focus;
//     then yabai's focused display is read, and one that is not his (the display holding Space 1) is a problem,
//     "display restore unsupported", naming the focus before and after (an app with no window on his display, Finder
//     with none, leaves the focused display, and his keystrokes, on CanvasTest). The check runs only while Tim has
//     chosen no app since the theft (his takeover or switch): asked as it begins, after each read that can block, and
//     in the turn that activates the modal. A modal the guard re-fronts (a revert's or this check's) is registered with
//     the restore policy in the turn that fronts it: its activation gives focus back, never Tim's takeover (review 4).
//     The before and after focus (front app, focused window or none, focused display, modal) are focusAtLaunch and
//     focusAtEnd;
//   - reads every display directly (SkyLight, the record yabai itself reads): at every Space notification, at each
//     activation, every 20 ms through each theft and grace window (macOS can report two changes in one
//     notification), around each Space restore, and once more at the end. Each change of Tim's display is in the
//     Space history. Each Space the tree shows him (a change at any moment of a theft window, or one that stays on
//     the Space the tree took him to) is a breach the moment it is read, once per excursion from his expected
//     Space, even when restored. SkyLight tells only the Space shown now: a Space shown between two reads can go
//     unnamed. So each notification must be explained by a change the reads found since the notification before
//     it, two reads positively naming two Spaces on one display: in a theft or grace window only a change of Tim's
//     own display explains one (sky-lead's decision A; another display's change never does, so a caller that
//     drives another display's Spaces during a guarded launch gets false failures by design); outside them any
//     display's does, and so does any display's for a notification whose interval began at or after Tim's takeover
//     (above). One that is not explained is a change and back that no read saw: in a theft or grace window (but
//     after his takeover) a breach that cannot be named (space-unseen), otherwise his own, as his changes are. This
//     rests on macOS posting at least one notification after each completed Space change [INFERENCE: not shown
//     here]. That the notifications arrive at all is checked (GR1): a change of any display that another read (an
//     activation's, a poll's, a restore's, the end's) finds must be followed by a notification within 0.5 s, or they
//     are not arriving: a problem, once per run. A change no read finds stays unchecked, so this can show them
//     missing only when a read finds a change. In a theft or grace window, reads more than 100 ms apart, and any
//     read that fails, leave a Space possibly unseen: a problem. As the guard ends, while a change a read found
//     waits for its notification, it waits for that (at most 0.5 s, the poll still running); then the poll stops;
//     then, in one main-queue turn, the watch takes its last read and is sealed (a change still waiting for its
//     notification then is a problem, however young) and the summary's records are taken; a notification after the
//     seal is a problem;
//   - restores Tim's Space: focusing the restore target, when it was last seen on the expected Space and its owner
//     checks out, brings that Space back, if a fresh read still wants it before each owner query and the focus;
//     each restore is recorded too. A change taken for Tim's is undone when a theft turns out to have come within
//     2 s of it;
//   - parks windows: each tree window that Accessibility reports created, focused or made main, and each tree
//     window yabai lists when the tree activates, the active Space changes, or (GR2, addendum 2) a tree window comes
//     on screen, is moved by id to --space. So every Space notification, and every tree window the guard sees come on
//     screen (the windows on screen, read every 100 ms from the launch on: a window not on screen at the read before),
//     re-checks the union of listed and all known tree windows, sampling omitted IDs through SkyLight and
//     WindowServer even after their 3 s retries end, and judging each such sample before its own yabai query (which
//     may be slow while the window closes): back on Tim's screen after a placement left it off, or there at the final
//     sweep, is a problem then; one never placed found on his screen is unresolved from that sample. Each newly shown
//     tree ID is sighted and parked individually, even with no AX event and no yabai row, and so is one already on
//     screen when its owner joins the tree (a window on screen whose owner was outside the tree is read again at the
//     first poll after the tree gains a root or an adoption); at the end, after its last adoption (its own scan), the
//     windows on screen are read once more and every tree window on them is sighted and judged by one sample, the
//     same for both (review 6) (review 4: before the final sweep's window list, which may wait while the window
//     closes): one on Tim's screen is a problem; one that sample shows gone (closed since that read) is judged by its
//     earlier samples if it had any (review 5), and counts as on Tim's screen if this was its first sighting (never
//     read anywhere: fail closed, review 6) (review 3; a read that fails then is a problem). macOS can show an
//     existing window again (a native tab selected again)
//     with no create event and no Space change. The guard keeps both yabai's last index and the measured Tim
//     membership.
//     Any of a window's SkyLight memberships in Tim's Spaces counts, even when yabai reports the target. A window
//     found on his screen after an off-Tim sample, or there at the final sweep, is a
//     problem, created or not. Its first placement there, where macOS opens new windows, is a move whose
//     onTimSpaceMs counts from the window's first Accessibility sighting (or the event that reported it) to the move:
//     past 250 ms it is a problem regardless of the move's destination or caller placement (GR1: 30-95 ms parks). At first sight each tree
//     window's Spaces and display are read from SkyLight directly, no yabai (firstSpace, firstDisplay, firstAt on its
//     records): a window SkyLight put on Tim's screen that yabai places elsewhere more than 250 ms later is a problem
//     too. A read of the windows on screen that fails is a problem. A window yabai will not place (no answer, or one
//     without its owner or Space) is asked about again every 50 ms for 3 s after the event that reported it and moved
//     as soon as yabai places it; then it is window-unknown (with WindowServer's and SkyLight's view of it), until
//     yabai places it (window-located). One never placed, still there at the end or gone before it, is a problem
//     unless every read of it (first sighting and every counted sample since) showed it off Tim's screen: its time
//     there cannot be bounded; that holds from its first
//     unplaced sample, so also when the guard ends within those 3 s. A window list that fails and a tree window still
//     off --space after its move are recorded as they happen; a list that leaves out an unknown window clears it (as
//     unknown; it stays unplaced) only if WindowServer shows it gone. A tree window still off --space after its
//     move is a problem (window-off-target; GR2, addendum 1).
//     Each sweep also reads all CGWindowList windows (including hidden Spaces) and enrolls omitted windows whose
//     native owner pid/start identity belongs to the tree (window-native-located, nativeWindows: id, pid, bounds and
//     on-screen state; a read that fails is one problem per run: a tree window yabai omits could go unseen).
//     Each is sampled directly first: an exempt one (below) is recorded and never asked about, so a sweep makes no
//     yabai query for a helper. Others are parked on a separate serial native lane, so a hung discovery/retry never
//     blocks AX/shown parks; a per-id gate prevents duplicate queries/mutations across lanes. Where yabai says it never tracked
//     a window (an id query that says it could not locate it), CG ownership/bounds and a complete SkyLight
//     membership sample may prove it already on the assigned agent Space and on no Tim/Tim-visible Space: that is
//     placed-native (untracked by yabai), recorded in nativePlacements, with no move and no yabai row. A membership
//     yabai's map cannot name, or Tim's visible assigned Space, is unplaced like any other reason (asked again every
//     50 ms for 3 s, then window-unknown) and fails closed at the end if nothing places it, whatever else excuses a
//     window; query timeouts and all earlier counted exposure fail closed too; no native move is made.
//     Helper windows (GR2, bench's ruling, GR1 addendum 4 note 3; every easl launch has a 1×1 window on screen for
//     ~1 s that yabai never lists, and 500×500 ones ordered out): "on Tim's screen" means ordered in on one of his
//     Spaces (SkyLight) with WindowServer bounds larger than 2×2 px. Each park samples the window so, directly, no
//     yabai (WindowLook), and so does the first sighting. Exempt, and only these: a window WindowServer has that
//     SkyLight puts on no Space (ordered out; kCGWindowIsOnscreen is no test, it is false for a window ordered in on a
//     Space no display shows too, and such a window on one of Tim's Spaces counts, in the end-state check too), and a
//     window whose bounds are 2×2 px or less (width and height both: a 1×500 strip counts). A state, Spaces or bounds
//     that cannot be read count as on his screen, with neither exemption: both require readable membership and
//     bounds and WindowServer presence. An exempt window is recorded (window-exempt: id, pid, bounds,
//     ordered state, Spaces; at the first sample of each exempt stretch and at the final sweep), never moved, never a
//     problem, and not unknown (its window-unknown is that record, never a fault). Each is sampled again every 100 ms
//     from its first sighting, before any yabai query finishes: one that orders in or grows past 2×2 px is judged from
//     the first sample that finds it counting (parked, window-counted; its exposure starts there); one gone is dropped.
//     That counted stretch is evidence until a placement judges it: if the window closes unplaced, it is never-placed
//     evidence (the sample showed it on his screen); if a sample finds it exempt again first, it counts as on his
//     screen for all the time from the counting sample to that exempt one, a problem past 250 ms (fail closed); a
//     sweep's sample of a window yabai's list omits ends it at that sample, before the window's own query (review 3).
//     A stretch no sample judged by the end (the park its counting sample queued, skipped as the guard ended) counts
//     until the end, past 250 ms a problem too (review 3); one of a window with an unresolved entry is merged into it
//     first, so earlier reads that showed it off Tim's screen no longer excuse it (review 4).
//     A final exemption is not permanent: after this guard exits, the wrapper's fresh window list is checked against
//     fresh WindowServer/SkyLight samples (--window-look, read-only, no activation or AppKit loop). A grown/ordered-in
//     window is judged by all its current memberships; any unreadable exemption proof fails the check.
//     --allow-caller-placement, for a caller that moves the tree's windows itself afterwards, changes only the
//     window-off-target verdict: a window off --space is still moved and recorded, but no problem when it is on a
//     Space and off Tim's screen (his Spaces 1-4, and the Space his display shows or should show, if not --space); one
//     on his screen, or on no Space, is a problem all the same. The start record and the summary name the placement
//     declared.
// The guard ends after --guard-seconds; when the launched tree has exited (without attach flags); when
// --parent-pid (gui-launch) exits, even by SIGKILL; on SIGTERM/SIGINT; or (--open) when no token-bearing
// process appeared within --adopt-timeout. On every end no new work starts (a theft then is not reverted, and is
// a problem); work in flight, including reverts still queued, gets 3 s to settle; the end's own work (the final
// scan, sweep and focus read) gets its own 5 s (GR2: the window list's two tries share one absolute 4 s deadline,
// including helper termination and reaping; each reply gets up to 2 s, shortened to leave cleanup time;
// one the retry reads is no problem, one neither try reads fails the check, and the tries and their latency are in
// the summary, finalWindowList); then every yabai helper still running is killed with its process
// group (SIGTERM, then SIGKILL) and reaped. Work that has not finished by then is a problem for the check; nothing
// is printed after guard-end. It never quits what it launched. An Objective-C exception, whether AppKit's loop caught
// it or nothing did, ends the guard at once instead, whatever the defaults say, within 0.5 s whether or not anyone
// drains its output: a best-effort error event (it may be missing), no summary, no helper teardown, exit 2.
// Events go to stdout as JSON lines; the summary gui-launch checks goes to --summary. Each activation's record
// (activation; reverted, for Tim's app given focus back) carries diagnostics that decide nothing: sinceInputMs, and
// previousFront, the app frontmost before it (in the tree or not, for how long, whether it has quit or is hidden;
// whether it just closed its last window is not known: the guard observes no window closes and asks nothing then).
// Threads: main runs NSApplication's own loop (except in the rig), the event loop macOS delivers Space
// notifications through: the guard is an AppKit app of its own class (GuardApplication) whose activation policy is
// .prohibited, so it has no Dock icon, no menu bar and no windows and is never activated; AppKit opens nothing for
// it, and a quit Apple Event ends it as SIGTERM does. Main handles workspace notifications, signals and
// gui-launch's exit, and never waits on a child
// process (a yabai call there is refused, and is a problem); reverts run on restoreQueue, Accessibility calls on
// axQueue (observer callbacks on their own run loop thread), window moves on yabaiQueue, Tim's restore target
// and Space restores on timQueue, the theft-window reads of his display on watchQueue, yabai's Space map on
// mapQueue, the process scan on scanQueue, the windows on screen on shownQueue, the baseline on startQueue and the
// end on endQueue.
// Every yabai call has one absolute deadline over its exit and the drain of its output (an output that reaches
// 16 MiB is refused, and a problem, whether or not the helper exits), runs in its own process group, and ends with
// that group: whatever it started is killed, and the leader reaped only once a whole listing of the group, every
// member of it read (one that cannot be read may be alive), shows it alone; the leader is reaped and released in
// the one locked turn in which the guard's end may signal it, so no released pid is ever signalled.
// Transient yabai reads get up to two attempts with 50 ms backoff inside one 4 s deadline including cleanup (at most
// 2 s per reply); definitive id misses are single-try. Restore-owner replies share the caller's 1 s deadline, with
// bounded cleanup outside it. Mutations are never retried. Recovered reads are no problem; exhausted reads remain
// fail-closed under the existing owner and window adjudications. Every yabai-query event carries its logical query's
// args, attempts, per-attempt error/latency, total latency and deadline. yabaiQueries retains the first 128 records;
// yabaiQueryStats preserves total/failed/retried/retained/dropped counts and total/max latency after that cap.
// The final list also keeps finalWindowList.
//
// usage: gui-launch-guard --space N --guard-seconds S --yabai PATH --summary PATH [--parent-pid P]
//            [--adopt-timeout S] [--allow-caller-placement] [--attach-exe E --attach-argv N]
//            [(--exec | --open) -- <argv to spawn>]
//        gui-launch-guard --screens   screen name -> CGDirectDisplayID (yabai's display "id"), as JSON
//        gui-launch-guard --window-look ID[,ID...]   read-only WindowServer/SkyLight samples for the wrapper's check
//                                     (--rig --onscreen PATH --skylight-windows PATH uses the test stand-ins)
//        gui-launch-guard --decide    tree, restore and Space decisions for synthetic processes on stdin (tests)
//        gui-launch-guard --resolve [--token T] [--attach-exe E --attach-argv N]
//                                     tree decisions for live processes named on stdin (tests)
//        gui-launch-guard --helpers --yabai PATH
//                                     yabai calls and the guard's end, driven from stdin (tests)
//        gui-launch-guard --rig --space N --yabai PATH --displays PATH --summary PATH [--guard-seconds S]
//            [--allow-caller-placement] [--onscreen PATH] [--skylight-windows PATH]
//                                     the guard in a session without a GUI: a stand-in yabai, a file standing in
//                                     for SkyLight's displays (one for WindowServer's windows, their bounds and
//                                     whether each is on screen, or none on screen and each unreadable; one for
//                                     SkyLight's read of each window's Spaces and display, or each unreadable),
//                                     and its events driven from stdin (tests)
// build: swiftc -O -swift-version 5 -target arm64-apple-macos13 \
//          -o ~/.local/bin/gui-launch-guard src/gui-launch-guard.swift
import AppKit
import ApplicationServices
import CryptoKit
import Security

// MARK: - Decisions (pure; --decide feeds them synthetic processes, activations, reverts and Spaces)

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

/// The theft windows: from a tree activation until focus is back with Tim's app (or, when there was none to give
/// it back to, with any app outside the tree), then `grace` more. Inside one, no activation and no Space change is
/// Tim's, but for his takeover (RestorePolicy.userInput): from it until the next tree activation, the Spaces his
/// display shows are his. Times are seconds since launch.
struct TheftWindow: Equatable {
    static let grace = 2.0
    private(set) var lastTheft: Double?
    /// A theft whose focus is not back yet.
    private(set) var open = false
    /// When the last window that closed ended: its return, plus `grace`.
    private(set) var closedUntil: Double?
    /// When Tim first took focus himself (RestorePolicy.userInput) since the last tree activation.
    private(set) var takenOver: Double?

    mutating func theft(at t: Double) {
        lastTheft = t
        open = true
        takenOver = nil
    }

    mutating func resolved(at t: Double) {
        guard open else { return }
        open = false
        closedUntil = t + TheftWindow.grace
    }

    mutating func takeover(at t: Double) { if takenOver == nil { takenOver = t } }

    /// Whether any moment from `t` until now lies in a theft window. Read after every theft known so far (each one
    /// came before now): a theft that is open, or a window that ended at or after `t`.
    func covers(since t: Double) -> Bool { open || (closedUntil ?? -.infinity) >= t }

    /// Whether what Tim's display showed from `t` on came after his takeover, with no tree activation since: his.
    func tims(since t: Double) -> Bool { takenOver.map { t >= $0 } ?? false }
}

/// What to do when an app becomes frontmost. `userFront` is the app to give focus back to: the frontmost app
/// at launch (if it is outside the tree), then each app outside the tree that became frontmost outside every theft
/// window, or within `userInput` of his HID input (Tim's own switch).
struct RestorePolicy {
    /// GR2 (addendum 3): an app outside the tree, other than the one focus goes back to, that becomes frontmost within
    /// this long of Tim's last HID input is his choice, in a theft or grace window too (his takeover). In the after-dark
    /// receipt (e8790f2c) each of his 12 activations came 2.7-47 ms after his input, and in the tab receipt
    /// (542d177d) 0.3 and 38.6 ms: 100 ms is about twice the slowest, with room for a main thread that serves the
    /// notification late. Never a tree app's activation.
    static let userInput = 0.1

    enum Decision: Equatable {
        case restore(to: pid_t)            // a tree process took focus: give it back
        case restored(latency: Double)     // the user's app is frontmost again; seconds since the theft
        case user                          // an app outside the tree, outside every theft window: Tim's new choice
        case tookOver                      // an app outside the tree within userInput of his input, in a theft or grace window: his
        case system                        // an app outside the tree inside a theft window: never taken for his
        case unrestorable                  // a tree process took focus and there is no app to give it back to
        case afterGuard
    }

    private(set) var userFront: pid_t?
    let guardUntil: Double
    /// When the tree took focus that is not back yet.
    private(set) var pendingSince: Double?
    private(set) var window = TheftWindow()
    /// GR2 item 6: the system modal (SecurityAgent, an authentication prompt) the guard re-fronted instead of Tim's
    /// app: its activation gives focus back as his app's would.
    private(set) var modal: pid_t?
    /// GR2 item 6 (review 3): how many times the app focus goes back to has changed since launch (his choice of an app,
    /// his takeover included, or the app dropped). A restore carries the count it began with and stops once it moves:
    /// Tim chose since.
    private(set) var choice = 0

    init(userFront: pid_t?, guardUntil: Double) {
        self.userFront = userFront
        self.guardUntil = guardUntil
    }

    /// The guard re-fronted system modal `pid` rather than front Tim's app over it (a revert, or the display check: GR2
    /// item 6, review 4). Its activation gives focus back, and is never his takeover.
    mutating func fronted(modal pid: pid_t) { modal = pid }

    /// `sinceInput`: seconds from Tim's last HID input to the activation (nil: not known).
    mutating func activation(pid: pid_t, inTree: Bool, at t: Double, sinceInput: Double? = nil) -> Decision {
        if t > guardUntil { return .afterGuard }
        if inTree {
            window.theft(at: t)
            if pendingSince == nil { pendingSince = t }
            guard let to = userFront else { return .unrestorable }
            return .restore(to: to)
        }
        if let since = pendingSince, pid == userFront || (modal != nil && pid == modal) {
            pendingSince = nil
            window.resolved(at: t)
            return .restored(latency: t - since)
        }
        // His takeover: never the app focus goes back to, nor a system modal the guard re-fronted (review 4), which the
        // guard's own reverts and restores activate.
        if pid != userFront, modal == nil || pid != modal, let input = sinceInput, input <= RestorePolicy.userInput {
            let inWindow = pendingSince != nil || window.covers(since: t)
            if pendingSince != nil {
                pendingSince = nil
                window.resolved(at: t)
            }
            window.takeover(at: t)
            userFront = pid
            choice += 1
            return inWindow ? .tookOver : .user
        }
        if pendingSince != nil && userFront == nil {  // nothing to give focus back to: the tree has lost it
            pendingSince = nil
            window.resolved(at: t)
            return .system
        }
        if window.covers(since: t) { return .system }
        userFront = pid
        choice += 1
        return .user
    }

    /// The app focus goes back to joined the tree or is gone: there is none until Tim picks one, and an open theft
    /// ends when any app outside the tree is frontmost.
    mutating func forgetUserFront() {
        userFront = nil
        choice += 1
    }

    /// Before a revert to `pid`, or its fallback activation: why it is no longer wanted (focus goes back to
    /// another app or none, or it is already back); nil: still wanted.
    func unwanted(_ pid: pid_t) -> String? {
        if userFront != pid { return "focus no longer goes back to pid \(pid)" }
        if pendingSince == nil { return "focus is already back with pid \(pid)" }
        return nil
    }
}

/// What yabai says about a window, asked just before it is focused.
enum WindowFact {
    case owner(pid_t, start: UInt64?, inTree: Bool, space: Int?)
    case unknown(String)
}

/// The window a revert focuses, with the Space it was last seen on: Tim's focused window at launch, then, after
/// each of his own app switches, the window yabai reports focused once it belongs to the app he switched to. The
/// app is remembered with its start time. A tree activation or an app activated in a theft window never changes
/// it; a window whose owner is in the tree (lineage, token or attach), or is the app he left (yabai lagging), is
/// never taken; and before every focus the app is checked again (one that is now another process or in the tree
/// is dropped, with its window), and so is the window's owner, by a query made for that focus: no earlier
/// verification vouches for it (a window can close, its id pass to the tree, without any event the guard sees).
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

    /// yabai reported window `id` of `owner` (started at `ownerStart`) on `space`; returns whether it is the
    /// target window now.
    mutating func verified(_ id: Int, owner: pid_t, ownerStart: UInt64?, ownerInTree: Bool, space: Int?) -> Bool {
        guard !ownerInTree, owner == pid, ownerStart != nil, ownerStart == start else {
            if id == window { located(id, space: nil) }  // the window turned out not to be his
            return false
        }
        window = id
        windowSpace = space
        return true
    }

    /// The target window's Space as last seen; nil: yabai no longer knows the window.
    mutating func located(_ id: Int, space: Int?) {
        guard id == window else { return }
        if space == nil { window = nil }
        windowSpace = space
    }

    /// Before a focus of window `id`: `fact`, from the owner query made for it. Returns why it may not be focused;
    /// nil: it is the target's.
    mutating func confirm(_ id: Int, _ fact: WindowFact) -> String? {
        switch fact {
        case .owner(let owner, let ownerStart, let inTree, let space):
            if verified(id, owner: owner, ownerStart: ownerStart, ownerInTree: inTree, space: space) { return nil }
            return "window \(id) belongs to pid \(owner)\(inTree ? ", in the tree" : ""), not to the restore target's app"
        case .unknown(let why):
            return why
        }
    }

    /// Before a focus or an activation: the target's app is still the process it was taken from (`current`: its
    /// start time now) and outside the tree. Otherwise there is no target any more.
    mutating func revalidate(start current: UInt64?, inTree: Bool) -> Bool {
        guard pid != nil else { return false }
        if inTree || current == nil || current != start {
            self = RestoreTarget(pid: nil, start: nil)
            return false
        }
        return true
    }
}

/// One owner query, judged against what was current when it began (the events seen, the restore target): `stale`
/// when something that could change what it vouches for came while it ran.
enum OwnerReply {
    case judged(String?)
    case stale
}

func staleOwner(_ id: Int) -> String {
    "yabai's answers about window \(id) were overtaken by an activation, a Space change or a new restore target, and no time was left to ask again"
}

/// What the owner check before a focus found: the window may be focused; it may not (why); or the focus is no
/// longer wanted at all (why), so no owner query is made again and nothing is focused or activated for it.
enum Vouch: Equatable {
    case vouched
    case refused(String)
    case unwanted(String)
}

/// The owner check before every focus of window `id`: `pending` says why the focus is no longer wanted (nil: it
/// still is), asked before each owner query; `ask` makes one owner query and judges its answer (nil: no time is
/// left for one); a stale answer is discarded and the query made again, while the focus is still wanted.
func vouch(_ id: Int, pending: () -> String?, ask: () -> OwnerReply?) -> Vouch {
    while true {
        if let why = pending() { return .unwanted(why) }
        guard let reply = ask() else { return .refused(staleOwner(id)) }
        if case .judged(let why) = reply { return why.map(Vouch.refused) ?? .vouched }
    }
}

/// How a revert gave focus back. `fronted`: the system modal its fallback re-fronted in place of Tim's app (GR2 item
/// 6; nil: his app, or nothing).
struct RevertOutcome {
    var method = "none"
    var ok = false
    var window: Int?
    var windowError: String?
    var reason: String?
    var fronted: pid_t?
}

/// The fallback's last step: its checks and the activation, in one turn of the main queue. GR2 item 6: `modal` when a
/// system modal was on screen, so its process was re-fronted (pid, owner name, whether the activation was made) and
/// nothing else was fronted over it; `refused` (review 3) when the windows on screen could not be read, so a modal
/// could not be ruled out and nothing was fronted (why).
enum FinalTurn {
    case activated(Bool)
    case modal(pid_t, String, Bool)
    case unwanted(String)
    case refused(String)
}

/// A revert: only while `unwanted` finds nothing against it (the app is still the process it was taken from,
/// outside the tree, still the one focus goes back to, focus not back yet). It focuses `window` once `confirm`
/// vouches that it is still that app's and `unwanted` still finds nothing, asked again after the owner check (which
/// may have taken a second, and given focus back meanwhile) immediately before the focus. Else, or when the focus
/// fails, `activate` re-activates the app in a turn that first asks the same again: the focus may have taken a
/// second, and the app may have joined the tree, exited, or had focus back. A focus no longer wanted ends the revert.
func performRevert(window: Int?, unwanted: () -> String?, confirm: (Int) -> Vouch, focus: (Int) -> String?,
                   activate: () -> FinalTurn) -> RevertOutcome {
    var outcome = RevertOutcome()
    if let why = unwanted() {
        outcome.reason = why
        return outcome
    }
    if let window {
        outcome.window = window
        switch confirm(window) {
        case .unwanted(let why):
            outcome.reason = why
            return outcome
        case .refused(let why):
            outcome.windowError = why
        case .vouched:
            if let why = unwanted() {
                outcome.reason = why
                return outcome
            }
            if let error = focus(window) {
                outcome.windowError = error
            } else {
                outcome.method = "window"
                outcome.ok = true
                return outcome
            }
        }
    }
    switch activate() {
    case .unwanted(let why), .refused(let why):
        outcome.reason = why
    case .activated(let ok):
        outcome.method = "activate"
        outcome.ok = ok
    case .modal(let modal, _, let ok):
        outcome.method = "modal"
        outcome.ok = ok
        outcome.fronted = modal
    }
    return outcome
}

/// What a read taken after a revert's activation showed: the frontmost app, and the Space Tim's display shows
/// (nil with `error`: the read failed).
struct PostFallbackRead {
    var front: pid_t?
    var space: Int?
    var error: String?
}

/// The owner query before a revert's focus ran out of time. It is expected-slow, and no problem, only if the window
/// was not focused (the owner check refused it, or focus was back first), an activation ran and succeeded (the one
/// made at once in the turn that decided the theft, which fronted `immediate`, or the revert's fallback, which its
/// checks let run), and `read`, taken after the revert, shows the app that activation fronted frontmost and Tim's
/// display on `expectedSpace`. That app is `pid`, or (GR2 item 6, review 3) the system modal re-fronted in its place.
/// Returns why it is a problem; nil: expected-slow.
func ownerTimeoutProblem(_ outcome: RevertOutcome, immediate: pid_t?, to pid: pid_t, expectedSpace: Int?, read: PostFallbackRead?) -> String? {
    if outcome.method == "window" { return "window \(outcome.window ?? 0) was focused without its owner vouched for" }
    let fellBack = outcome.method == "activate" || outcome.method == "modal"
    if immediate == nil {
        guard fellBack else { return "no activation gave focus back: the fallback activation did not run: \(outcome.reason ?? "no reason recorded")" }
        guard outcome.ok else { return "no activation gave focus back: the fallback activation of pid \(outcome.fronted ?? pid) failed" }
    }
    let front = fellBack && outcome.ok ? outcome.fronted ?? pid : immediate ?? pid
    guard let read else { return "no read was taken after the activation" }
    if let error = read.error { return "the read after the activation failed: \(error)" }
    guard read.front == front else {
        let modal = front == pid ? "" : " (the system modal re-fronted in place of pid \(pid))"
        return "after the activation \(read.front.map { "pid \($0)" } ?? "no app") is frontmost, not pid \(front)\(modal)"
    }
    guard let expectedSpace, read.space == expectedSpace else {
        return "after the activation Tim's display shows \(read.space.map { "Space \($0)" } ?? "a Space yabai does not list"), not Space \(expectedSpace.map { String($0) } ?? "?")"
    }
    return nil
}

/// The Space Tim's display should show. A change of it at any moment of a theft window, or one that stays on the
/// Space the tree took it to, is the tree's: restore it by focusing his restore-target window, if that window was
/// last seen on the expected Space. Any other change is his own and becomes the expected Space, until a theft turns
/// out to have come within `grace` of it (the change may reach the guard before the theft does): then the Space
/// before it is expected again. Each Space the tree shows him is a breach once per excursion: from leaving the
/// expected Space until it is shown again (or he switches himself), however often it is read. Each Space
/// notification must be explained by a change the reads found (SpaceNotices). In a theft or grace window (any moment
/// since the notification before it) only a change of Tim's own display explains it (sky-lead's decision A): any
/// other, one that coincides with another display's change included, is a change and back unseen, the tree's, a
/// breach that cannot be named. Outside them another display's change explains it too, and one that nothing
/// explains is his, until a theft turns out to have come within `grace` of it. GR2 (addendum 3): after Tim's takeover
/// (an app outside the tree he activated, RestorePolicy.userInput) and until the next tree activation, each change
/// is his, in a theft or grace window too (but one that stays on the Space the tree took him to); so is a
/// notification since the one before it came at or after the takeover, judged as outside a window (another display's
/// change explains it, and one nothing explains is his); and a theft that came before the takeover revokes or
/// charges none of them. A Space is its yabai index, or, for one yabai's map does not know, minus its SkyLight id
/// (spaceKey).
struct SpacePolicy {
    enum Decision: Equatable {
        case unchanged
        case user(Int)
        case restore(from: Int, to: Int, window: Int)
        case unrestorable(from: Int, to: Int)
    }

    /// What a Space notification was: explained by the change of a display (its identifier), the tree's (a change
    /// and back unseen, a breach), or taken for Tim's.
    enum Notice: Equatable {
        case explained(String)
        case tree
        case tim
    }

    private(set) var expected: Int?
    /// The Space the tree moved Tim's display to, while it still shows it.
    private(set) var thiefSpace: Int?
    /// The changes lately taken for Tim's: the Space expected before each, the one after, and when it began.
    private(set) var rebases: [(from: Int, to: Int, since: Double)] = []
    /// The Space the last `observed` stopped expecting because a theft came within `grace` of Tim's change to it.
    private(set) var revoked: Int?
    /// The Spaces the tree has shown him in this excursion.
    private(set) var seen = Set<Int>()
    /// The Space the last `observed` found the tree showing for the first time in this excursion: a breach.
    private(set) var breach: Int?
    /// The notifications nothing explained that were taken for Tim's, by when they were read, kept 2 × `grace`.
    private(set) var unseenOutside: [Double] = []
    /// The ones of them the last `observed` charged to the tree: a theft came within `grace` of each.
    private(set) var unseenCharged: [Double] = []

    init(expected: Int?) { self.expected = expected }

    /// A Space notification read at `t`; the one before it was read at `since`. `tim`: Tim's display, if the reads
    /// since then named two different Spaces on it; `others`: the other displays they did that for. GR2: once Tim
    /// took over (TheftWindow.tims) at or before `since`, the whole interval is his: judged as outside a theft window.
    mutating func noticed(at t: Double, since: Double, theft: TheftWindow, tim: String?, others: [String]) -> Notice {
        unseenOutside.removeAll { t - $0 > 2 * TheftWindow.grace }
        if let tim { return .explained(tim) }
        if theft.covers(since: since) && !theft.tims(since: since) { return .tree }
        if let other = others.first { return .explained(other) }
        unseenOutside.append(t)
        return .tim
    }

    /// Tim's display showed `visible` at some moment from `since` (the read, or the event that reported a change)
    /// until now; `theft` is read now, so a theft that came since counts. `window` is his restore target and
    /// `windowSpace` the Space it was last seen on (nil: gone).
    mutating func observed(_ visible: Int, since: Double, theft: TheftWindow, window: Int?, windowSpace: Int?) -> Decision {
        revoked = nil
        breach = nil
        unseenCharged = []
        if let lastTheft = theft.lastTheft {
            // A notification taken for Tim's after his takeover is his: no theft before the takeover charges it.
            let charged = { (at: Double) in abs(lastTheft - at) <= TheftWindow.grace && !theft.tims(since: at) }
            unseenCharged = unseenOutside.filter(charged)
            unseenOutside.removeAll(where: charged)
        }
        if let lastTheft = theft.lastTheft,
           let first = rebases.firstIndex(where: { abs(lastTheft - $0.since) <= TheftWindow.grace && !theft.tims(since: $0.since) }) {
            revoked = expected
            expected = rebases[first].from
            rebases.removeSubrange(first...)
            seen.removeAll()
        }
        guard let want = expected else { return .unchanged }
        if visible == want {
            thiefSpace = nil
            seen.removeAll()
            return .unchanged
        }
        if visible != thiefSpace && (!theft.covers(since: since) || theft.tims(since: since)) {
            rebases.removeAll { since - $0.since > 2 * TheftWindow.grace }
            rebases.append((want, visible, since))
            expected = visible
            thiefSpace = nil
            seen.removeAll()
            return .user(visible)
        }
        thiefSpace = visible
        if seen.insert(visible).inserted { breach = visible }
        guard let window, windowSpace == want else { return .unrestorable(from: visible, to: want) }
        return .restore(from: visible, to: want, window: window)
    }
}

/// A Space for SpacePolicy: its yabai index, or minus its SkyLight id when yabai's map does not know it.
func spaceKey(index: Int?, id: UInt64) -> Int { index ?? -Int(truncatingIfNeeded: id) }
/// A Space for a record: its index, or null (the record carries the id) when yabai's map does not know it.
func spaceField(_ key: Int) -> Any { key > 0 ? key : NSNull() }

/// yabai's Spaces by SkyLight id (`yabai -m query --spaces`: "id" is SkyLight's): the index of each, and the id of
/// Space 1, which marks Tim's display. nil: a row without a numeric id and index, or no Space 1.
struct SpaceMap: Equatable {
    let indexes: [UInt64: Int]
    let anchor: UInt64

    init?(_ spaces: Any?) {
        guard let rows = spaces as? [[String: Any]] else { return nil }
        var indexes: [UInt64: Int] = [:]
        for row in rows {
            guard let id = (row["id"] as? NSNumber)?.uint64Value, let index = (row["index"] as? NSNumber)?.intValue else { return nil }
            indexes[id] = index
        }
        guard let anchor = indexes.first(where: { $0.value == 1 })?.key else { return nil }
        self.indexes = indexes
        self.anchor = anchor
    }
}

/// One read of SkyLight's managed display Spaces, [{"Display Identifier", "Current Space": {"id64"}, "Spaces":
/// [{"id64"}, …]}, …] ("ManagedSpaceID" where "id64" is missing): the Space Tim's display (the one holding Space
/// `anchor`, which is how it is known from read to read) shows, by SkyLight id, and the Space each other display
/// shows, by its identifier. Only positive readings are kept: another display without an identifier (or sharing one)
/// or without a readable current Space is left out, so nothing about it can count as a change. nil: unreadable, or
/// no display (or more than one) holds `anchor`, or his shows no readable Space.
struct DisplayRead: Equatable {
    /// Tim's display's identifier, for the record ("" without one).
    let tim: String
    let timSpace: UInt64
    let others: [String: UInt64]

    init?(_ displays: Any?, anchor: UInt64) {
        func id(_ space: Any?) -> UInt64? {
            guard let space = space as? [String: Any] else { return nil }
            return ((space["id64"] ?? space["ManagedSpaceID"]) as? NSNumber)?.uint64Value
        }
        guard let displays = displays as? [[String: Any]] else { return nil }
        let holding = displays.filter { ($0["Spaces"] as? [Any])?.contains(where: { id($0) == anchor }) == true }
        guard holding.count == 1, let timSpace = id(holding[0]["Current Space"]) else { return nil }
        let tim = holding[0]["Display Identifier"] as? String ?? ""
        var others: [String: UInt64] = [:]
        var keys = Set<String>(), shared = Set<String>()
        for display in displays where !((display["Spaces"] as? [Any])?.contains(where: { id($0) == anchor }) == true) {
            guard let key = display["Display Identifier"] as? String, !key.isEmpty, key != tim else { continue }
            if !keys.insert(key).inserted { shared.insert(key) }
            if let current = id(display["Current Space"]) { others[key] = current }
        }
        for key in shared { others[key] = nil }
        self.tim = tim
        self.timSpace = timSpace
        self.others = others
    }
}

/// Whether each Space notification can be explained: by Tim's display, or another, when two reads of it (of every
/// display, at each notification and poll) since the previous notification's read positively named two different
/// Spaces on it. A display left out of a read, or unreadable, never counts as changed. A notification that nothing
/// explains means a change and back that no read saw: SkyLight tells only the Space each display shows now, never
/// the ones it passed through, and keeps no history of them, so such a Space cannot be named. (Which changes may
/// explain a notification, and when, is SpacePolicy.noticed's.)
/// [INFERENCE] macOS posts at least one activeSpaceDidChange after each completed Space change of any display
/// (several changes may share one). Apple documents only that it is posted "when a Spaces change occurs", with no
/// count, no coalescing rule and no userInfo; no source found shows a completed change that posts none, nor proves
/// that none ever does; and no per-transition source (SkyLight's 1401 and 1329 events included) is documented as
/// lossless. Under it, an excursion of Tim's display between two reads, however short, leaves a notification that
/// no read of his display explains. That is not checked here: the guard relies on it. That notifications arrive at
/// all is checked (NoticeFeed). Times: seconds since launch.
struct SpaceNotices: Equatable {
    /// The last Space each display was positively read to show (Tim's apart).
    private(set) var lastTim: UInt64?
    private(set) var lastOthers: [String: UInt64] = [:]
    /// Whether Tim's display, and which other displays (in the order found), were read to change since the last
    /// notification's read.
    private(set) var timChanged = false
    private(set) var othersChanged: [String] = []
    /// When the last notification was read (at first, when the watch began).
    private(set) var since: Double

    init(since: Double) { self.since = since }

    /// A read of every display. Returns whether it found Tim's display, and which other displays, showing another
    /// Space than at their last positive reading.
    @discardableResult
    mutating func read(_ read: DisplayRead) -> (tim: Bool, others: [String]) {
        var changed: (tim: Bool, others: [String]) = (false, [])
        if let lastTim, lastTim != read.timSpace {
            timChanged = true
            changed.tim = true
        }
        for (key, now) in read.others.sorted(by: { $0.key < $1.key }) {
            if let before = lastOthers[key], before != now {
                changed.others.append(key)
                if !othersChanged.contains(key) { othersChanged.append(key) }
            }
            lastOthers[key] = now
        }
        lastTim = read.timSpace
        return changed
    }

    /// A notification, read at `t` (after `read`, if the read succeeded; `readOK`: false, it failed, and then
    /// nothing explains it). Returns whether Tim's display changed, the other displays that did, and when the
    /// notification before it was read.
    mutating func notified(at t: Double, readOK: Bool) -> (tim: Bool, others: [String], since: Double) {
        defer {
            timChanged = false
            othersChanged.removeAll()
            since = t
        }
        guard readOK else { return (false, [], since) }
        return (timChanged, othersChanged, since)
    }
}

/// Whether the reads of Tim's display prove that no Space shown to him went unseen. While a theft or grace window
/// is watched (from when the guard learned of it), consecutive reads may be at most `maxGap` apart (the poll reads
/// every `interval`): a Space shown only within a longer gap may be unseen. Times: seconds since launch.
struct SpaceSampling: Equatable {
    static let interval = 0.02
    static let maxGap = 0.1
    /// When the watched window began; nil: none is watched.
    private(set) var watchingSince: Double?
    /// The last read, whether it succeeded or not.
    private(set) var lastRead: Double?

    mutating func watch(at t: Double) { if watchingSince == nil { watchingSince = t } }
    mutating func unwatch() { watchingSince = nil }

    /// A read at `t`. Returns when the gap it ends began, if the watched window went longer than `maxGap` unread.
    mutating func read(at t: Double) -> Double? {
        defer { lastRead = t }
        guard let since = watchingSince else { return nil }
        let from = max(lastRead ?? since, since)
        return t - from > SpaceSampling.maxGap ? from : nil
    }
}

/// GR1: whether macOS's Space notifications reach the guard at all. A Space notification's read must follow each
/// change of any display (Tim's or another; decision A needs both) that another read found (an activation's, a
/// poll's, a restore's, the end's) within `limit`: without them the checks that rest on them (SpaceNotices: a change
/// and back that no read saw, decision A) are blind, and fail open. A notification names no display, so any one
/// follows every change waiting. The first change that waits longer than `limit`, or that still waits when the guard
/// seals its records however young it is, is missed: a problem, once per run, after which nothing is tracked. (The
/// guard's end waits up to `limit`, the poll still running, for a change still waiting to get its notification.) A
/// change no read finds still goes unchecked: this can show the notifications missing only when a read finds a
/// change. [INFERENCE] macOS posts the notification within `limit` of the change SkyLight's record shows: a later
/// one fails the check. Times: seconds since launch.
struct NoticeFeed: Equatable {
    static let limit = 0.5
    struct Change: Equatable {
        /// When the read that found it was taken.
        let at: Double
        /// The display's identifier; nil: Tim's display.
        let display: String?
        /// The Space it showed then, by SkyLight id.
        let space: UInt64
        let via: String
    }
    /// The changes found since the last notification's read, oldest first.
    private(set) var waiting: [Change] = []
    /// The change no notification followed, once there is one.
    private(set) var missed: Change?

    /// A read at `t`, before what it found: the change that has waited longer than `limit`, if one has.
    mutating func read(at t: Double) -> Change? {
        guard missed == nil, let oldest = waiting.first, t - oldest.at > NoticeFeed.limit else { return nil }
        return miss(oldest)
    }

    /// What a read other than a notification's found.
    mutating func found(_ changes: [Change]) {
        if missed == nil { waiting += changes }
    }

    /// A notification's read (after `read(at:)`): it follows every change still waiting.
    mutating func notified() { waiting.removeAll() }

    /// The seal, after its read: a change still waiting is missed, however young.
    mutating func seal() -> Change? {
        guard missed == nil, let oldest = waiting.first else { return nil }
        return miss(oldest)
    }

    /// Whether a change still waits that has waited at most `limit` at `t`.
    func pending(at t: Double) -> Bool { waiting.contains { t - $0.at <= NoticeFeed.limit } }

    private mutating func miss(_ change: Change) -> Change {
        missed = change
        waiting.removeAll()
        return change
    }
}

/// A whole list from `list`, which fills at most the buffer's count of entries and returns how many it filled
/// (negative: an error): the buffer starts at `slots` and grows fourfold, up to `maxSlots`, until the list fits
/// with a slot to spare. nil: unreadable, or still full at `maxSlots`: a list that may be cut short is never taken
/// for whole.
func listWhole(slots: Int, maxSlots: Int, _ list: (inout [pid_t]) -> Int) -> [pid_t]? {
    var size = max(slots, 1)
    while size <= maxSlots {
        var buffer = [pid_t](repeating: 0, count: size)
        let filled = list(&buffer)
        if filled < 0 { return nil }
        if filled < size { return Array(buffer[..<filled]) }
        size *= 4
    }
    return nil
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

/// GR1-F1/F2: an Objective-C exception ends the guard at once, as a failure, and nothing it waits on can stop that:
/// first a watchdog thread is armed that exits 2 after 0.5 s whatever else blocks (armExitWatchdog); then, best
/// effort, the `error` event (if stdout's lock is free within 0.2 s and nothing ended the output) and the message on
/// stderr, each one write made only if its pipe can take it at once (writeIfReady), so an output nobody drains is
/// skipped, never waited on; then exit 2, which gui-launch fails. Nothing else runs: the exception may have left any
/// lock held and any record half made (Swift code does not unwind it), so no summary is written and the yabai helpers
/// are left to end on their own, as on a crash. `thrown`: what was raised (an NSException, or any object);
/// `inAppKit`: AppKit's loop caught it (GuardApplication); else nothing caught it (the uncaught-exception handlers).
func exceptionEnds(_ thrown: Any?, inAppKit: Bool) -> Never {
    armExitWatchdog()
    func capped(_ text: String, _ bytes: Int) -> String { String(decoding: Array(text.utf8.prefix(bytes)), as: UTF8.self) }
    let exception = thrown as? NSException
    let name = capped(exception?.name.rawValue ?? thrown.map { "a \(type(of: $0))" } ?? "nil", 100)
    let reason = capped(exception?.reason ?? "no reason given", 200)
    let message = "an Objective-C exception \(inAppKit ? "in AppKit's loop" : "that nothing caught") (\(name): \(reason)) " +
        "ended the guard at once: its records are incomplete"
    // The lock stays held: nothing is printed after the error event, or in its place.
    if outLock.lock(before: Date(timeIntervalSinceNow: 0.2)) {
        if !outputClosed, var line = try? JSONSerialization.data(withJSONObject: ["event": "error", "message": message, "at": iso()],
                                                                 options: [.sortedKeys, .withoutEscapingSlashes]) {
            line.append(10)
            if line.count <= Int(PIPE_BUF) { writeIfReady(1, Array(line)) }  // a JSON line goes whole, or not at all
        }
        outputClosed = true
    }
    writeIfReady(2, Array(("gui-launch-guard: " + message + "\n").utf8))
    _exit(2)
}

/// GR1-F2: a thread of its own (no queue, no lock, no output) that exits 2 once 0.5 s have passed, so the guard's
/// end on an exception never waits on anything for longer. (alarm would end it by SIGALRM, not exit 2.)
/// GR1-F3: a watchdog that cannot start exits 2 at once, with no diagnostics: they would have no deadline.
func armExitWatchdog() {
    var thread: pthread_t?
    guard pthread_create(&thread, nil, { _ in
        var want = timespec(tv_sec: 0, tv_nsec: 500_000_000)
        var left = timespec()
        while nanosleep(&want, &left) == -1 && errno == EINTR { want = left }
        _exit(2)
    }, nil) == 0 else { _exit(2) }
    if let thread { pthread_detach(thread) }
}

/// GR1-F2: one write to `fd` of at most PIPE_BUF bytes, made only if poll shows that `fd` can take it now: a pipe
/// shows writable only with PIPE_BUF bytes free, and a write that small goes in whole, so it does not block (unless
/// another process fills the pipe in between: the watchdog bounds that). Not O_NONBLOCK: that flag belongs to the
/// open file description, which the guard's stdout and stderr share with gui-launch, its caller and (stderr) the
/// launched app, whose writes it would make fail once the guard is gone.
func writeIfReady(_ fd: Int32, _ bytes: [UInt8]) {
    var ready = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    guard poll(&ready, 1, 0) == 1, ready.revents & Int16(POLLOUT) != 0 else { return }
    let count = min(bytes.count, Int(PIPE_BUF))
    _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, count) }
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

/// What one read of a helper's output gave.
enum Chunk { case bytes, wouldBlock, closed }

/// Why a drain stopped.
enum DrainStop: String { case wouldBlock = "would-block", closed, full, deadline }

/// Reads with `read` (which appends to `data`) until the source would block or is closed, `data` holds `cap`
/// bytes, or `deadline` passes. The deadline is checked before every read, so a writer that never lets the pipe
/// run dry cannot hold the caller past it, and the cap keeps one that writes without end from filling memory.
func drain(_ data: inout Data, cap: Int, deadline: Double, now: () -> Double, read: (inout Data) -> Chunk) -> DrainStop {
    while true {
        if data.count >= cap { return .full }
        if now() >= deadline { return .deadline }
        switch read(&data) {
        case .bytes: continue
        case .wouldBlock: return .wouldBlock
        case .closed: return .closed
        }
    }
}

/// The first listing's slots for a group's members (--helpers makes it small, to exercise the paging).
var groupListSlots = 1024

/// What proc_pidinfo says of a listed group member: alive, a zombie (dead already: its parent reaps it), gone (no
/// such process any more), or unreadable (any other failure: it may be alive).
enum MemberState: String { case live, zombie, gone, unreadable }

func memberState(_ pid: pid_t) -> MemberState {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
    let got = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
    if got == size { return info.pbi_status == 5 ? .zombie : .live }  // 5: SZOMB
    return got == 0 && errno == ESRCH ? .gone : .unreadable
}

/// The live members among a group's listed `pids`; nil: one could not be read, so the group cannot be shown empty
/// of live members (a cleanup failure, never an absence).
func liveMembers(_ pids: [pid_t], _ state: (pid_t) -> MemberState) -> [pid_t]? {
    var live: [pid_t] = []
    for pid in pids where pid > 0 {
        switch state(pid) {
        case .live: live.append(pid)
        case .zombie, .gone: continue
        case .unreadable: return nil
        }
    }
    return live
}

/// The live processes in process group `pgid`; nil: the group could not be listed whole, or a member could not be
/// read.
func groupMembers(_ pgid: pid_t) -> [pid_t]? {
    let stride = MemoryLayout<pid_t>.stride
    guard let pids = listWhole(slots: groupListSlots, maxSlots: 1 << 20, { buffer in
        let bytes = buffer.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(pgid), $0.baseAddress, Int32($0.count)) }
        return bytes < 0 ? -1 : Int(bytes) / stride
    }) else { return nil }
    return liveMembers(pids, memberState)
}

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

/// A spawned helper, the leader of its own process group: its output drained (at most `outputCap` bytes) and its
/// exit noted under one absolute deadline. The leader stays unreaped until `end`, so its pid, which names the
/// group, cannot pass to another process while the group is cleared.
final class Child {
    /// Space reserved inside an operation's absolute deadline for TERM, KILL and reaping.
    static let cleanupAllowance = 0.8
    static let outputCap = 16 << 20
    private static let chunk = 65536
    let pid: pid_t
    let output: Int32
    private(set) var data = Data()
    private(set) var eof = false
    private(set) var full = false
    private(set) var exited = false
    private(set) var reaped = false
    private var status: Int32 = 0
    private let buffer = UnsafeMutableRawPointer.allocate(byteCount: Child.chunk, alignment: 16)

    init(pid: pid_t, output: Int32) {
        self.pid = pid
        self.output = output
        _ = fcntl(output, F_SETFL, O_NONBLOCK)
    }

    deinit { buffer.deallocate() }

    var code: Int32 { (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f) }

    /// Drains what output there is, until `deadline`, and notes whether the leader exited, without reaping it.
    private func step(until deadline: Double) {
        if !eof && !full {
            let fd = output, chunk = self.buffer
            switch drain(&data, cap: Child.outputCap, deadline: deadline, now: uptime, read: { data in
                let n = read(fd, chunk, Child.chunk)
                if n > 0 {
                    data.append(chunk.assumingMemoryBound(to: UInt8.self), count: n)
                    return .bytes
                }
                if n < 0 && errno == EINTR { return .bytes }
                return n < 0 && errno == EAGAIN ? .wouldBlock : .closed
            }) {
            case .closed: eof = true
            case .full: full = true
            case .wouldBlock, .deadline: break
            }
        }
        if !exited {
            var info = siginfo_t()
            if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 {
                exited = info.si_pid == pid
            } else if errno == ECHILD {  // reaped elsewhere: its status is lost, so it counts as a failure
                exited = true
                reaped = true
                status = 255 << 8
            }
        }
    }

    /// Until the leader has exited and the output is closed (by it and anything it started), the output is full
    /// (its answer is refused then, whatever the helper does next), or `deadline` (uptime) passes. Returns whether
    /// it finished.
    func wait(until deadline: Double) -> Bool {
        while true {
            step(until: deadline)
            if full || (exited && eof) { return true }
            let left = deadline - uptime()
            if left <= 0 { return false }
            if eof || full {
                usleep(UInt32(min(left, 0.001) * 1_000_000))
            } else {
                var ready = pollfd(fd: output, events: Int16(POLLIN), revents: 0)
                _ = poll(&ready, 1, Int32((left * 1000).rounded(.up)))
            }
        }
    }

    /// Ends the group, on every path. Unless a whole listing of the group shows the exited leader alone, its
    /// members (what the helper left behind, whether or not it still holds the output) get SIGTERM, then SIGKILL
    /// after 0.3 s: the leader is unreaped, so the group is still its own. Then, holding `lifecycle` (the lock
    /// under which alone the guard's end signals a helper's group, and only one still registered), the leader is
    /// reaped if a whole listing shows it alone, and `release` deregisters it in that same turn: no pid is
    /// signalled once it is released. Returns whether the leader was reaped alone; a group that cannot be listed
    /// whole keeps its leader unreaped.
    func end(until deadline: Double = .infinity, lifecycle: NSLock, release: () -> Void) -> Bool {
        if !reaped && !(exited && others()?.isEmpty == true) {
            killpg(pid, SIGTERM)
            if !settled(until: min(uptime() + 0.3, deadline - 0.5)) {
                killpg(pid, SIGKILL)
                _ = settled(until: min(uptime() + 0.5, deadline))
            }
        }
        lifecycle.lock(); defer { lifecycle.unlock() }
        let alone = others()?.isEmpty == true
        if exited && alone && !reaped {
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            reaped = true
        }
        release()
        return reaped && alone
    }

    private func others() -> [pid_t]? { groupMembers(pid)?.filter { $0 != pid } }

    private func settled(until deadline: Double) -> Bool {
        while true {
            step(until: deadline)
            if exited && others()?.isEmpty == true { return true }
            let left = deadline - uptime()
            if left <= 0 { return false }
            usleep(UInt32(min(left, 0.002) * 1_000_000))
        }
    }
}

/// Whether this code runs on the main thread or the main queue (which dispatchMain() serves from another thread).
let mainQueueKey = DispatchSpecificKey<Bool>()
DispatchQueue.main.setSpecific(key: mainQueueKey, value: true)
func onMain() -> Bool { Thread.isMainThread || DispatchQueue.getSpecific(key: mainQueueKey) == true }

/// The guard's yabai helpers. Each runs in its own process group under one absolute deadline over its exit and
/// the drain of its output, and ends with its group (Child.end); one whose output reaches the cap is refused, and
/// that is a problem, whether or not it exits (so a caller that owns its timeout never takes it for a timeout); one
/// that misses the deadline is reported (a problem and a yabai-timeout event), unless its caller owns the timeout.
/// None runs on the main thread or queue (refused, and a problem), none starts
/// after shutdown(), and shutdown() ends those still running. `lock` is the helpers' lifecycle lock: a helper is
/// registered when spawned, and its leader reaped and released in one turn under it (Child.end), and shutdown
/// signals under it only the groups still registered, whose leaders are therefore unreaped: no released pid is
/// ever signalled. (Nothing else in the guard reaps a helper.)
final class Helpers {
    enum Reply {
        case exited(Int32, Data)
        case timedOut(Double)
        case refused(String)
    }

    private let lock = NSLock()
    private var running: [pid_t: String] = [:]
    /// Ended by shutdown().
    private var ended = Set<pid_t>()
    private var closed = false
    /// No call started from now on runs past this (uptime): the guard's end sets one per stage.
    private var cap = Double.infinity

    func limit(until deadline: Double) {
        lock.lock(); defer { lock.unlock() }
        cap = deadline
    }

    /// Effective query reply allowance under the current end-stage cap; no retry starts after the cap closes it.
    func queryAllowance(until deadline: Double) -> Double {
        lock.lock(); defer { lock.unlock() }
        return closed ? 0 : max(0, min(deadline, cap) - uptime() - Child.cleanupAllowance)
    }

    /// `ownsTimeout`: the caller records a timeout itself (the owner query before a revert's focus).
    /// `until`: one operation's absolute deadline, including helper cleanup; reserve cleanupAllowance before replying.
    /// `released` (tests): called once the call's group is ended, with whether its pid is still registered.
    func run(_ path: String, _ args: [String], timeout: Double, ownsTimeout: Bool = false, until: Double? = nil,
             captureError: Bool = false, released: ((Bool) -> Void)? = nil) -> Reply {
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
        if captureError { posix_spawn_file_actions_adddup2(&actions, fds[1], 2) }
        else { posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0) }
        var attributes = childAttributes(onlyListedFds: true)
        let argv = ([path, "-m"] + args).map { strdup($0) } + [nil]
        var pid: pid_t = 0
        var spawned: Int32 = -1
        lock.lock()
        let begun = uptime()
        let cleanupDeadline = min(cap, until ?? .infinity)
        let allowed = min(timeout, cap - begun, until.map { min($0, cap) - begun - Child.cleanupAllowance } ?? .infinity)
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
        let child = Child(pid: pid, output: fds[0])
        let finished = child.wait(until: deadline)
        var killedAtEnd = false
        let groupEnded = child.end(until: until == nil ? .infinity : cleanupDeadline, lifecycle: lock) {
            running[pid] = nil
            killedAtEnd = ended.remove(pid) != nil
        }
        close(fds[0])
        if let released {
            lock.lock()
            let registered = running[pid] != nil
            lock.unlock()
            released(registered)
        }
        if !groupEnded { problem("\(what) (process group \(pid)) could not be ended and reaped: its group could not be shown empty") }
        if killedAtEnd { return .refused("\(what) was killed at the guard's end") }
        if child.full {
            let message = "\(what) wrote more than \(Child.outputCap) bytes: its answer was refused"
            problem(message)
            return .refused(message)
        }
        guard finished else {
            if !ownsTimeout {
                let seconds = String(format: "%.1f", allowed)
                problems.update { $0.append("\(what) did not answer within \(seconds) s") }
                emit(["event": "yabai-timeout", "args": args, "timeoutS": decimal(allowed, 1)])
            }
            return .timedOut(allowed)
        }
        return .exited(child.code, child.data)
    }

    /// The guard's end: no helper starts any more, and each still registered gets SIGTERM, then SIGKILL after
    /// 0.3 s, with its group, all under the lifecycle lock; the call that started it ends the group, reaps and
    /// releases it. Returns what they were.
    func shutdown() -> [String] {
        lock.lock()
        closed = true
        let victims = running
        ended.formUnion(victims.keys)
        for pid in victims.keys { killpg(pid, SIGTERM) }
        lock.unlock()
        guard !victims.isEmpty else { return [] }
        if !gone(Array(victims.keys), within: 0.3) {
            lock.lock()
            let left = victims.keys.filter { running[$0] != nil }
            for pid in left { killpg(pid, SIGKILL) }
            lock.unlock()
            _ = gone(left, within: 1.0)
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

/// Work that may run a yabai helper (a park, a sweep, a Space check, a restore-target check, a revert, the
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

    /// nil: the guard is ending, and this is not the end's own work (`final`), which runs within endWork.
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

    /// Waits until no work is in flight or `seconds` pass; returns the work still in flight, by id.
    func settle(within seconds: Double) -> [Int: String] {
        let limit = Date().addingTimeInterval(seconds)
        condition.lock(); defer { condition.unlock() }
        while !active.isEmpty && condition.wait(until: limit) {}
        return active
    }
}

let helpers = Helpers()
let inFlight = InFlight()
var stopping: Bool { inFlight.isClosed }

/// Work begun on the queue that runs it (a park, a sweep, a Space check): skipped once the guard is ending,
/// unless it is the end's own (`final`).
func tracked(_ what: String, final: Bool = false, _ body: () -> Void) {
    guard let id = inFlight.begin(what, final: final) else { return }
    defer { inFlight.end(id) }
    body()
}

/// Work handed to `queue` from the main thread (a revert, the baseline) or the --helpers driver: registered before
/// it is queued, so the guard's end waits for it however long it sits in the queue; once the end has begun it is
/// refused, and that is a problem.
@discardableResult
func schedule(_ what: String, on queue: DispatchQueue, _ body: @escaping () -> Void) -> Bool {
    guard let id = inFlight.begin(what) else {
        problem("\(what) came after the guard's end began: not run")
        return false
    }
    queue.async {
        defer { inFlight.end(id) }
        body()
    }
    return true
}

/// How long work in flight gets to finish once the guard ends, and how long the end's own work then gets: GR2, 5 s,
/// room for the final window list's two tries of 2 s and the rest of the end's work.
let settleSeconds = 3.0
let finalSeconds = 5.0

/// The guard's end, on every path (and in --helpers), once inFlight is closed: work in flight gets
/// `settleSeconds`; then `finalWork` gets its own `finalSeconds` (no yabai call it starts runs past them); then
/// every helper still running is ended and reaped, and the work that lost its helper gets 0.5 s to unwind. Work
/// that did not settle, each helper ended, and any work still unfinished after that is a problem. Never on main.
func endWork(_ finalWork: () -> Void) -> (unsettled: [String], killed: [String]) {
    helpers.limit(until: uptime() + settleSeconds)
    let unsettled = inFlight.settle(within: settleSeconds)
    for what in unsettled.values.sorted() { problem("\(what) was still running \(settleSeconds) s into the guard's end") }
    helpers.limit(until: uptime() + finalSeconds)
    finalWork()
    let killed = helpers.shutdown()
    for what in killed { problem("\(what) was still running at the guard's end: killed") }
    let left = inFlight.settle(within: 0.5)
    for (id, what) in left.sorted(by: { $0.key < $1.key }) where unsettled[id] == nil {
        problem("\(what) had not finished when the guard ended")
    }
    return (unsettled.values.sorted(), killed)
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
    /// Counts each root added and each adoption: a `contains` answer may have changed since (ShownWindows).
    private var grown = 0

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
        grown += 1
    }

    /// Changes whenever the tree gains a root or an adoption.
    var generation: Int {
        lock.lock(); defer { lock.unlock() }
        return grown
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
        grown += 1
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

/// Why a window could not be vouched for before a focus.
func unanswered(_ id: Int) -> String { "yabai did not say in time who owns window \(id)" }
func unknownWindow(_ id: Int) -> String { "yabai knows no window \(id)" }

/// stdin: a header `{"front": pid|null, "frontWindow": id|null, "frontWindowSpace": n|null, "guardSeconds": S,
/// "token": T, "attach": {"exe", "needle"}, "before": [pid], "roots": [pid], "timSpace": n, "procs": [...]}` (all
/// but front and guardSeconds optional), then rows. `procs`, `[{"pid", "ppid", "start", "exe", "argv", "env",
/// "unreadable"}]`, defines synthetic processes (replacing any with the same pid; "start": null means gone, absent
/// means 1; "unreadable": true hides its arguments and environment); "before" pids are snapshotted with their
/// start times then. In the header, as at the guard's start, attach members among the header's procs join the
/// tree before the front app and its window become the restore target. Each Space row and each activation starts a
/// new epoch, as the live guard's events do. A row is one of
/// - `{"t", "activate": pid, "input": s, "focused": {"id", "pid", "space"}, "revert": {…}}`: an activation; `input`,
///   when Tim's last HID input came (seconds since launch; absent: not known), whose takeover (RestorePolicy.userInput)
///   the row reports as "takeover"; `focused`, the
///   window yabai reports focused afterwards. A tree activation's row reports "immediate", the app the activation
///   made at once in its own turn activates (null, with "immediateRefused", when the fallback's checks refuse it);
///   `revert`, the revert it starts: "verify" is what each
///   owner query answers in turn (`{"pid", "space"}`, "gone", or null; a single answer stands for a list of one;
///   an answer missing: none in time), "duringQuery" (activation rows) comes while the first owner query runs,
///   "afterVouch" (activation rows) comes once an owner answer vouched for the window, before the focus,
///   "focus": "fail" fails the focus, "duringFocus" (`{"procs", "t", "activate"}`) happens while the focus runs,
///   "mainQueue" (rows) is work the main queue serves before the fallback's final turn, "afterFallback"
///   (`{"front": pid, "space": n}`; absent: the read failed) is what the read after the revert shows, and "modal"
///   (pid) is a system modal on screen, which the activation made at once and the fallback's final turn re-front in
///   place of his app;
/// - `{"t", "launch": pid}` (an app launch or a scan sighting), `{"t", "move": pid}` (the check before a move);
/// - `{"t", "space": n, "since": s, "windowSpace": n|null, "duringQuery": [activation rows]}`: Tim's display
///   showed Space n at some moment from `since` (default t) until t, the activations came while the query ran,
///   and windowSpace is the Space his restore-target window was last seen on (null: gone);
/// - `{"t", "read": n}` (or `{"t", "read": null, "id": i}`: a Space yabai's map does not know): a direct read of
///   his display at t; it takes "windowSpace" too. A Space row reports the unexplained notifications it charges to
///   the tree ("unseenCharged");
/// - `{"t", "notice": s, "tim": true|false, "others": [display]}`: a Space notification read at t, the one before
///   it read at s; "tim", whether reads of Tim's display named two Spaces since then, "others" the other displays
///   they did that for: "explained" (with "explainedBy"), "tree" or "tim".
/// - `{"t", "feed": via, "changes": [{"display": d|null, "space": id}], "seal": true|false}` (NoticeFeed): a read of
///   the displays at t, via "notification" or another read that found `changes` (display null: Tim's), then, with
///   "seal", the seal: "missed" (`{"at", "display", "space", "via", "sealed"}`, or null), "waiting" (how many
///   changes still wait) and "pending" (one still within the limit).
/// Other keys (such as "input" on any other row) play no part. stdout: one line per row.
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
    var feed = NoticeFeed()
    var epoch = 0
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
    /// As the live guard's `unwanted`.
    func unwanted(_ to: pid_t) -> String? {
        if let why = policy.unwanted(to) { return why }
        if revalidate() == nil { return nil }
        return "pid \(to) joined the tree or is another process now"
    }
    func resolution(_ result: Lineage.Resolution, into out: inout [String: Any]) {
        out["tree"] = result.inTree
        if let adoption = result.adopted { out["attached"] = ["pid": Int(adoption.pid), "rule": adoption.rule.rawValue] as [String: Any] }
        if !result.dropped.isEmpty { out["dropped"] = result.dropped.map(Int.init) }
    }
    var activation: ([String: Any]) -> [String: Any] = { _ in [:] }
    func revert(to: pid_t, _ spec: [String: Any], immediate: pid_t?) -> [String: Any] {
        var queries = 0
        var timedOut = false
        var activated: pid_t?
        var during: [String: Any]?
        var duringQuery: [[String: Any]] = []
        var afterVouch: [[String: Any]] = []
        var focusTried = false
        var queued: [[String: Any]] = []
        var answers: [Any] = spec["verify"] as? [Any] ?? spec["verify"].map { [$0] } ?? []
        let outcome = performRevert(
            window: target.window(for: to),
            unwanted: { unwanted(to) },
            confirm: { id in
                let found = vouch(id, pending: { unwanted(to) }) {
                    queries += 1
                    let began = (epoch: epoch, target: target)
                    if queries == 1 { duringQuery = (spec["duringQuery"] as? [[String: Any]] ?? []).map { activation($0) } }
                    let answer: Any? = answers.isEmpty ? nil : answers.removeFirst()
                    let fact: WindowFact
                    if let reply = answer as? [String: Any], let owner = pid(reply["pid"]) {
                        fact = .owner(owner, start: source.start(owner), inTree: inTree(owner), space: number(reply["space"])?.intValue)
                    } else if answer as? String == "gone" {
                        fact = .unknown(unknownWindow(id))
                    } else {
                        timedOut = true
                        fact = .unknown(unanswered(id))
                    }
                    guard epoch == began.epoch && target == began.target else { return .stale }
                    return .judged(target.confirm(id, fact))
                }
                if found == .vouched { afterVouch = (spec["afterVouch"] as? [[String: Any]] ?? []).map { activation($0) } }
                return found
            },
            focus: { _ in
                focusTried = true
                if let happening = spec["duringFocus"] as? [String: Any] {
                    define(happening["procs"])
                    if happening["activate"] != nil { during = activation(happening) }
                }
                return spec["focus"] as? String == "fail" ? "exit 1" : nil
            },
            activate: {
                // Work queued on the main queue ahead of the final turn is served first; then the turn's checks and
                // the activation, with nothing between them.
                queued = (spec["mainQueue"] as? [[String: Any]] ?? []).map { activation($0) }
                if let why = unwanted(to) { return .unwanted(why) }
                if let modal = pid(spec["modal"]) {  // a system modal on screen: re-fronted in place of his app
                    activated = modal
                    return .modal(modal, "SecurityAgent", true)
                }
                activated = to
                return .activated(true)
            })
        var out: [String: Any] = ["method": outcome.method, "ok": outcome.ok, "window": outcome.window ?? NSNull(),
                                  "windowError": outcome.windowError ?? NSNull(), "reason": outcome.reason ?? NSNull(),
                                  "queried": queries > 0, "queries": queries, "activated": activated.map { Int($0) } ?? NSNull(),
                                  "focusTried": focusTried]
        if let during { out["duringFocus"] = during }
        if !duringQuery.isEmpty { out["duringQuery"] = duringQuery }
        if !afterVouch.isEmpty { out["afterVouch"] = afterVouch }
        if !queued.isEmpty { out["mainQueue"] = queued }
        if timedOut {
            var read = PostFallbackRead(error: "Tim's display could not be read")
            if let shown = spec["afterFallback"] as? [String: Any] { read = PostFallbackRead(front: pid(shown["front"]), space: number(shown["space"])?.intValue) }
            let why = ownerTimeoutProblem(outcome, immediate: immediate, to: to, expectedSpace: spaces.expected, read: read)
            out["ownerTimeout"] = ["expectedSlow": why == nil, "problem": why ?? NSNull()] as [String: Any]
        }
        return out
    }
    activation = { row in
        define(row["procs"])
        let t = number(row["t"])?.doubleValue ?? 0
        guard let p = pid(row["activate"]) else { return [:] }
        var out: [String: Any] = ["t": t, "pid": Int(p)]
        let result = lineage.resolve(p, adopting: true, source)
        resolution(result, into: &out)
        epoch += 1
        if let dropped = revalidate() { out["targetDropped"] = Int(dropped) }
        let sinceInput = number(row["input"]).map { t - $0.doubleValue }
        let decision = policy.activation(pid: p, inTree: result.inTree, at: t, sinceInput: sinceInput)
        switch decision {
        case .restore(let to):
            out["decision"] = "restore"
            out["to"] = Int(to)
            out["window"] = target.window(for: to) ?? NSNull()
            // The activation made at once, in this turn, after the checks of the fallback's final turn (a system modal
            // the revert names, `modal`, is re-fronted in place of his app).
            let refused = unwanted(to)
            let spec = row["revert"] as? [String: Any]
            let fronted = refused == nil ? spec.flatMap { pid($0["modal"]) } ?? to : nil
            out["immediate"] = fronted.map { Int($0) as Any } ?? NSNull()
            if let refused { out["immediateRefused"] = refused }
            if let spec { out["revert"] = revert(to: to, spec, immediate: fronted) }
        case .restored(let latency):
            out["decision"] = "restored"
            out["latencyMs"] = ms(latency)
        case .user, .tookOver:
            out["decision"] = "user"
            if decision == .tookOver { out["takeover"] = true }
            target.userSwitched(to: p, start: source.start(p))
        case .system: out["decision"] = "system"
        case .unrestorable: out["decision"] = "unrestorable"
        case .afterGuard: out["decision"] = "after-guard"
        }
        if let focused = row["focused"] as? [String: Any], let id = number(focused["id"])?.intValue, let owner = pid(focused["pid"]) {
            _ = target.verified(id, owner: owner, ownerStart: source.start(owner), ownerInTree: inTree(owner),
                                space: number(focused["space"])?.intValue)
        }
        out["target"] = target.window ?? NSNull()
        return out
    }
    while let line = readLine() {
        guard !line.isEmpty, let data = line.data(using: .utf8),
              let row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
        define(row["procs"])
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
        if row["activate"] != nil {
            out = activation(row)
        } else if let p = pid(row["launch"]) {
            out["pid"] = Int(p)
            resolution(lineage.resolve(p, adopting: true, source), into: &out)
        } else if let p = pid(row["move"]) {
            out["pid"] = Int(p)
            resolution(lineage.resolve(p, adopting: false, source), into: &out)
        } else if row["space"] is NSNumber || row.keys.contains("read") {
            let reading = row.keys.contains("read")
            let visible: Int
            if reading {
                guard let key = number(row["read"])?.intValue ?? number(row["id"]).map({ -$0.intValue }) else { continue }
                visible = key
            } else {
                visible = number(row["space"])!.intValue
                epoch += 1
            }
            let during = (row["duringQuery"] as? [[String: Any]] ?? []).map { activation($0) }
            if !during.isEmpty { out["duringQuery"] = during }
            if let window = target.window, row.keys.contains("windowSpace") { target.located(window, space: number(row["windowSpace"])?.intValue) }
            if let dropped = revalidate() { out["targetDropped"] = Int(dropped) }
            let since = reading ? t : number(row["since"])?.doubleValue ?? t
            let decision = spaces.observed(visible, since: since, theft: policy.window, window: target.window, windowSpace: target.windowSpace)
            if let revoked = spaces.revoked { out["revoked"] = revoked }
            if let breach = spaces.breach { out["breach"] = breach }
            if !spaces.unseenCharged.isEmpty { out["unseenCharged"] = spaces.unseenCharged }
            switch decision {
            case .unchanged: out["space"] = "unchanged"
            case .user(let space): out["space"] = "user"; out["expected"] = space
            case .restore(let from, let to, let window): out["space"] = "restore"; out["from"] = from; out["to"] = to; out["window"] = window
            case .unrestorable(let from, let to): out["space"] = "unrestorable"; out["from"] = from; out["to"] = to
            }
        } else if let since = number(row["notice"])?.doubleValue {
            epoch += 1
            let tim: String? = row["tim"] as? Bool == true ? "tim" : nil
            switch spaces.noticed(at: t, since: since, theft: policy.window, tim: tim, others: row["others"] as? [String] ?? []) {
            case .explained(let display):
                out["notice"] = "explained"
                out["explainedBy"] = display
            case .tree: out["notice"] = "tree"
            case .tim: out["notice"] = "tim"
            }
        } else if let via = row["feed"] as? String {
            func record(_ change: NoticeFeed.Change, sealed: Bool) -> [String: Any] {
                ["at": change.at, "display": change.display ?? NSNull(), "space": NSNumber(value: change.space), "via": change.via,
                 "sealed": sealed]
            }
            out["missed"] = NSNull()
            if let late = feed.read(at: t) { out["missed"] = record(late, sealed: false) }
            if via == "notification" {
                feed.notified()
            } else {
                feed.found((row["changes"] as? [[String: Any]] ?? []).compactMap { change in
                    number(change["space"]).map { NoticeFeed.Change(at: t, display: change["display"] as? String, space: $0.uint64Value, via: via) }
                })
            }
            if row["seal"] as? Bool == true, let late = feed.seal() { out["missed"] = record(late, sealed: true) }
            out["waiting"] = feed.waiting.count
            out["pending"] = feed.pending(at: t)
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
    case .exited(let code, let data) where data.count > 4096: return ["reply": "exit", "code": Int(code), "bytes": data.count]
    case .exited(let code, let data): return ["reply": "exit", "code": Int(code), "out": String(decoding: data, as: UTF8.self)]
    case .timedOut: return ["reply": "timeout"]
    case .refused(let why): return ["reply": "refused", "why": why]
    }
}

/// stdin lines, read on a thread that stands for the main thread:
/// - `call <id> <timeout> <args…>`: a yabai call on a concurrent queue, scheduled as work in flight;
/// - `owner <id> <timeout> <args…>`: the same for a caller that owns its timeout (the owner query before a focus);
/// - `queued <id> <timeout> <args…>`: the same on a serial queue, as reverts are (they wait behind each other);
/// - `main <id> <args…>`: the call on the main queue;
/// - `final <timeout> <args…>`: a call for the end's own stage, in order;
/// - `drain <deadline> <cap>`: the drain over a source that never runs dry, on a clock that ticks 1 ms per look;
/// - `release <id> <timeout> <args…>`: a call that reports, as soon as its group is ended, whether its pid was
///   still registered with the helpers then (the end could still signal it);
/// - `slots <n>`: the first listing of a helper group's members gets n slots, so a larger group needs paging;
/// - `list <total> <slots> [fail]`: listWhole over a source of `total` entries (or one that fails);
/// - `members <state…>`: the live members among listed pids 1, 2, … whose proc_pidinfo reads as each state says
///   (live, zombie, gone, unreadable);
/// - `end`: the guard's end, as finish() starts it: work in flight is closed here, endWork runs on another queue.
/// stdout: `{"ready": true}`, the events, `{"call": id, "reply": …}` per call (written before the call stops
/// being in flight), `{"final": n, "reply": …}`, `{"drain", "bytes", "reads"}`, `{"released": id, "registered"}`,
/// `{"slots": n}`, `{"list": count|null, "tries": n}`, `{"members": [pid]|null}`, and `{"end": {"unsettled",
/// "killed", "problems"}}`. Exits at the end of stdin, once the end is done.
func helpersMode(yabai path: String) -> Never {
    writeLine(["ready": true])
    let calls = DispatchQueue(label: "gui-launch.calls", attributes: .concurrent)
    let serial = DispatchQueue(label: "gui-launch.queued")
    let ender = DispatchQueue(label: "gui-launch.ender")
    let ending = DispatchGroup()
    func call(_ id: String, _ timeout: Double, _ args: [String], on queue: DispatchQueue, ownsTimeout: Bool = false) {
        let scheduled = schedule("call \(id)", on: queue) {
            writeLine(describe(helpers.run(path, args, timeout: timeout, ownsTimeout: ownsTimeout)).merging(["call": id]) { $1 })
        }
        if !scheduled { writeLine(["call": id, "reply": "not started"]) }
    }
    Thread {
        var finals: [(timeout: Double, args: [String])] = []
        while let line = readLine() {
            let words = line.split(separator: " ").map(String.init)
            if words.count >= 3, ["call", "queued", "owner"].contains(words[0]), let timeout = Double(words[2]) {
                call(words[1], timeout, Array(words[3...]), on: words[0] == "queued" ? serial : calls, ownsTimeout: words[0] == "owner")
            } else if words.count >= 2, words[0] == "members" {
                let states = words.dropFirst().map { MemberState(rawValue: $0) ?? .unreadable }
                let live = liveMembers(Array(1...pid_t(states.count))) { states[Int($0) - 1] }
                writeLine(["members": live.map { $0.map(Int.init) as Any } ?? NSNull()])
            } else if words.count >= 3, words[0] == "release", let timeout = Double(words[2]) {
                let id = words[1], args = Array(words[3...])
                let scheduled = schedule("call \(id)", on: calls) {
                    let reply = helpers.run(path, args, timeout: timeout) { registered in writeLine(["released": id, "registered": registered]) }
                    writeLine(describe(reply).merging(["call": id]) { $1 })
                }
                if !scheduled { writeLine(["call": id, "reply": "not started"]) }
            } else if words.count == 2, words[0] == "slots", let slots = Int(words[1]) {
                groupListSlots = slots
                writeLine(["slots": slots])
            } else if words.count >= 3, words[0] == "list", let total = Int(words[1]), let slots = Int(words[2]) {
                let failing = words.count > 3
                var tries = 0
                let listed = listWhole(slots: slots, maxSlots: 1 << 20) { buffer in
                    tries += 1
                    if failing { return -1 }
                    let filled = min(total, buffer.count)
                    for i in 0..<filled { buffer[i] = pid_t(i + 1) }
                    return filled
                }
                writeLine(["list": listed.map { $0.count as Any } ?? NSNull(), "tries": tries])
            } else if words.count >= 2, words[0] == "main" {
                let id = words[1], args = Array(words[2...])
                DispatchQueue.main.async { writeLine(describe(helpers.run(path, args, timeout: 2)).merging(["call": id]) { $1 }) }
            } else if words.count >= 2, words[0] == "final", let timeout = Double(words[1]) {
                finals.append((timeout, Array(words[2...])))
            } else if words.count == 3, words[0] == "drain", let deadline = Double(words[1]), let cap = Int(words[2]) {
                var data = Data()
                var tick = 0, reads = 0
                let stop = drain(&data, cap: cap, deadline: deadline, now: {
                    defer { tick += 1 }
                    return Double(tick) / 1000
                }, read: { data in
                    reads += 1
                    data.append(contentsOf: repeatElement(UInt8(0x7b), count: 1000))
                    return .bytes
                })
                writeLine(["drain": stop.rawValue, "bytes": data.count, "reads": reads])
            } else if words == ["end"] {
                inFlight.close()
                let stage = finals
                ending.enter()
                ender.async {
                    let (unsettled, killed) = endWork {
                        for (n, call) in stage.enumerated() {
                            writeLine(describe(helpers.run(path, call.args, timeout: call.timeout)).merging(["final": n + 1]) { $1 })
                        }
                    }
                    writeLine(["end": ["unsettled": unsettled, "killed": killed, "problems": problems.value] as [String: Any]])
                    ending.leave()
                }
            }
        }
        ending.wait()
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
var resolving = false, helperTest = false, rigTest = false
/// --allow-caller-placement (GR2, addendum 1): the caller moves the tree's windows itself afterwards, so a tree window
/// off --space after the guard's move is no problem, but only when it is off Tim's screen (onTimsScreen) and on a Space.
var allowCallerPlacement = false
var displaysPath: String?
var onscreenPath: String?  // --onscreen (rig): the file standing in for WindowServer's windows (rigServerWindows)
var skylightWindowsPath: String?  // --skylight-windows (rig): the file standing in for SkyLight's read of windows
var windowLookIds: String?
var parentWatch: pid_t?
var attachExe: String?, attachNeedle: String?, givenToken: String?
var launchArgv: [String] = []
while !argv.isEmpty {
    let flag = argv.removeFirst()
    if flag == "--" { launchArgv = argv; break }
    if flag == "--exec" || flag == "--open" { mode = String(flag.dropFirst(2)); continue }
    if flag == "--resolve" { resolving = true; continue }
    if flag == "--helpers" { helperTest = true; continue }
    if flag == "--rig" { rigTest = true; continue }
    if flag == "--allow-caller-placement" { allowCallerPlacement = true; continue }
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
    case "--displays": displaysPath = value
    case "--onscreen": onscreenPath = value
    case "--skylight-windows": skylightWindowsPath = value
    case "--window-look": windowLookIds = value
    default: fail("unknown flag \(flag)")
    }
}
if let value = windowLookIds {
    let parts = value.split(separator: ",", omittingEmptySubsequences: false)
    let ids = parts.compactMap { Int($0) }
    guard !ids.isEmpty, ids.count == parts.count, ids.allSatisfy({ $0 > 0 }), mode == nil, launchArgv.isEmpty,
          !resolving, !helperTest, attachExe == nil, attachNeedle == nil,
          rigTest || (onscreenPath == nil && skylightWindowsPath == nil) else { fail("usage: --window-look ID[,ID...]") }
    readWindowLooks(ids)
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
if rigTest {
    guard space > 0, guardSeconds > 0, guardSeconds.isFinite, !yabaiPath.isEmpty, !summaryPath.isEmpty, displaysPath != nil,
          mode == nil, matcher == nil, parentWatch == nil else {
        fail("usage: --rig --space N --yabai PATH --displays PATH --summary PATH [--guard-seconds S] [--allow-caller-placement] " +
             "[--onscreen PATH] [--skylight-windows PATH]")
    }
} else {
    guard displaysPath == nil else { fail("--displays is for --rig: the guard reads Tim's display from SkyLight") }
    guard onscreenPath == nil, skylightWindowsPath == nil else {
        fail("--onscreen and --skylight-windows are for --rig: the guard reads WindowServer and SkyLight")
    }
    guard space > 0, guardSeconds > 0, guardSeconds.isFinite, adoptTimeout > 0, adoptTimeout.isFinite,
          !yabaiPath.isEmpty, !summaryPath.isEmpty, (mode == nil) == launchArgv.isEmpty, mode != nil || matcher != nil else {
        fail("usage: --space N --guard-seconds S --yabai PATH --summary PATH [--parent-pid P] [--adopt-timeout S] " +
             "[--allow-caller-placement] [--attach-exe E --attach-argv N] [(--exec | --open) -- argv]")
    }
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
/// GR2 item 6: Tim's display (yabai's index of the display holding Space 1), from the baseline; read by restores.
var timDisplay: Int?
var policy = RestorePolicy(userFront: nil, guardUntil: guardSeconds)  // main thread
/// policy's theft windows, published by main as each activation is decided, for the reads of Tim's display: read
/// at each read, never a copy queued behind it.
let theftState = Locked(TheftWindow())
/// Activations, Space changes, and app launches and exits so far: an owner answer counts only while this has not
/// moved since its query began.
let timEpoch = Locked(0)
let restoreTarget = Locked(RestoreTarget(pid: nil, start: nil))
let spacePolicy = Locked(SpacePolicy(expected: nil))
let spaceEvents = Locked([[String: Any]]())
let moves = Locked([[String: Any]]())
/// The owner queries before a revert's focus that ran out of time, as recorded (owner-query-timeout).
let ownerTimeouts = Locked([[String: Any]]())
/// Where the tree's windows could not be learned: the windows yabai would not place (by id, with why), until a
/// window list places them or no longer has them; and why the last window list failed (nil: it answered).
let windowsUnknown = Locked([Int: String]())
let windowListFailure = Locked(String?.none)
/// window-unknown, window-list-failed and window-off-target, as recorded.
let windowFaults = Locked([[String: Any]]())
/// GR2: the Space the guard last saw each tree window on, by id (kept for the guard's whole run: a list may leave out a
/// window, a hidden tab, that macOS shows again later).
let windowSpaces = Locked([Int: Int]())
/// The measured last sample, not yabai's single Space: a sticky window can stay on the same yabai index as it re-shows.
let windowOnTims = Locked([Int: Bool]())
let spaceWatch = SpaceWatch()
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
let nativeParkQueue = DispatchQueue(label: "gui-launch.native-parks")
let axQueue = DispatchQueue(label: "gui-launch.ax")
let timQueue = DispatchQueue(label: "gui-launch.tim")
let scanQueue = DispatchQueue(label: "gui-launch.scan")
let restoreQueue = DispatchQueue(label: "gui-launch.restore")
let startQueue = DispatchQueue(label: "gui-launch.start")
let endQueue = DispatchQueue(label: "gui-launch.end")
let watchQueue = DispatchQueue(label: "gui-launch.watch", qos: .userInteractive)
let mapQueue = DispatchQueue(label: "gui-launch.map")
let shownQueue = DispatchQueue(label: "gui-launch.shown")

// MARK: - Tim's input

let anyInputEvent = unsafeBitCast(UInt32.max, to: CGEventType.self)  // kCGAnyInputEventType

/// When the last HID input (keyboard, mouse, trackpad) came, in seconds since launch, as the HID system's
/// event-source table says. Process-generated events can update that table. It is logged (sinceInputMs) and decides
/// only Tim's takeover (RestorePolicy.userInput), never a Space change on its own.
func lastInput() -> Double? {
    let since = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInputEvent)
    return since.isFinite && since >= 0 ? uptime() - t0 - since : nil
}

// MARK: - yabai (off the main thread, every call bounded)

let queryTimeout = 2.0
/// Ordinary reads share the final list's 4 s budget, including cleanup. Owner replies retain their 1 s budget,
/// split across two attempts; each helper's cleanup is bounded separately. Mutations are never retried.
let queryLimit = 4.0
let queryTries = 2
let queryBackoff = 0.05
struct QueryHistory {
    static let capacity = 128
    var rows: [[String: Any]] = []
    var total = 0, failed = 0, retried = 0
    var latency = 0.0, longest = 0.0
    mutating func append(_ row: [String: Any], ok: Bool, retry: Bool, seconds: Double) {
        total += 1
        if !ok { failed += 1 }
        if retry { retried += 1 }
        latency += seconds
        longest = max(longest, seconds)
        if rows.count < Self.capacity { rows.append(row) }
    }
    var stats: [String: Any] {
        ["total": total, "failed": failed, "retried": retried, "retained": rows.count, "dropped": total - rows.count,
         "capacity": Self.capacity, "totalMs": ms(latency), "maxMs": ms(longest)]
    }
}
let yabaiQueries = Locked(QueryHistory())
/// A focus on the restore path. While Studio launched, yabai let window queries run past 0.5 s and a query plus
/// a focus took 258 ms (counter-ball receipt 20261006T040054Z): twice the deadline that failed. A focus that
/// misses it falls back to re-activating the app (580 ms there).
let focusTimeout = 1.0

/// A logical read, with each attempt and its latency. A transient timeout is not a problem; exhaustion still is.
/// The caller may own timeout adjudication (restore-owner checks and the final list). No native fallback can turn
/// a query that never answers into a successful query. Definitive id misses are single-try; transient reads retry.
/// `replyUntil`: an owner reply deadline, with bounded cleanup outside it as before; `until` includes cleanup.
@Sendable func queryReply(_ args: [String], timeout: Double = queryTimeout, ownsTimeout: Bool = false,
                         until: Double? = nil, replyUntil: Double? = nil) -> (reply: Helpers.Reply, value: Any?, record: [String: Any]) {
    let began = uptime()
    let replyDeadline = replyUntil ?? until ?? began + queryLimit
    let cleanupDeadline = replyUntil.map { $0 + Child.cleanupAllowance } ?? replyDeadline
    let limit = max(0, replyDeadline - began)
    let what = "yabai -m " + args.joined(separator: " ")
    var reply: Helpers.Reply = .refused("\(what) has no time left")
    var tries: [[String: Any]] = []
    var ok = false
    var value: Any?
    var timedOut = false
    var connectionFailure: String?
    for n in 1...queryTries {
        let at = uptime()
        let available = min(replyDeadline - at, helpers.queryAllowance(until: cleanupDeadline))
        guard available > 0 else { break }
        // Reserve backoff and scheduling slack, not the helper's entire cleanup allowance, from owner replies.
        let allowed = replyUntil != nil && n == 1
            ? min(timeout, max(0.001, (available - queryBackoff - 0.05) / 2)) : min(timeout, available)
        reply = helpers.run(yabaiPath, args, timeout: allowed, ownsTimeout: true, until: cleanupDeadline, captureError: true)
        var why: String?
        var retry = true
        switch reply {
        case .exited(0, let data):
            value = data.isEmpty ? nil : json(data)
            if value != nil { ok = true }
            else { why = "\(what) answered unreadably" }
        case .exited(let code, let data):
            why = "\(what) exited \(code)"
            if code == 1 {
                let message = String(decoding: data, as: UTF8.self)
                if message.contains("failed to connect to socket") {
                    connectionFailure = "\(what) could not connect to yabai"
                    why = connectionFailure
                    retry = false
                } else if args.count == 4, args[1] == "--windows", args[2] == "--window",
                          message.contains("could not locate window with the specified id") {
                    retry = false
                }
            }
        case .timedOut(let seconds):
            timedOut = true
            why = "\(what) did not answer within \(String(format: "%.1f", seconds)) s"
        case .refused(let reason):
            why = reason
            retry = false  // lifecycle, output-cap and spawn refusals are not transient query answers
        }
        tries.append(["try": n, "ms": ms(uptime() - at), "error": why ?? NSNull()])
        if ok || !retry || n == queryTries { break }
        let left = min(replyDeadline - uptime(), helpers.queryAllowance(until: cleanupDeadline))
        guard left > queryBackoff else { break }
        usleep(UInt32(queryBackoff * 1_000_000))
    }
    if !ok && timedOut { reply = .timedOut(limit) }  // a later refusal must never erase an unanswered attempt
    let elapsed = uptime() - began
    let record: [String: Any] = ["event": "yabai-query", "args": args, "ok": ok, "tries": tries,
                                 "retried": tries.count > 1, "limitS": decimal(limit, 3), "ms": ms(elapsed)]
    yabaiQueries.update { $0.append(record, ok: ok, retry: tries.count > 1, seconds: elapsed) }
    emit(record)  // the stream retains each attempt even after the bounded summary is full
    if !ok && timedOut && !ownsTimeout {
        problems.update { $0.append("\(what) did not answer within \(String(format: "%.1f", limit)) s (bounded query retries exhausted)") }
        emit(["event": "yabai-timeout", "args": args, "timeoutS": decimal(limit, 3)])
    } else if !ok, let connectionFailure { problem(connectionFailure) }
    return (reply, value, record)
}

@Sendable func yabaiReply(_ args: [String], timeout: Double = queryTimeout, ownsTimeout: Bool = false,
                         until: Double? = nil) -> Helpers.Reply {
    return helpers.run(yabaiPath, args, timeout: timeout, ownsTimeout: ownsTimeout, until: until)
}

@Sendable func json(_ data: Data) -> Any? { data.isEmpty ? [:] as [String: Any] : try? JSONSerialization.jsonObject(with: data) }

@Sendable func yabai(_ args: [String], timeout: Double = queryTimeout) -> Any? {
    let read = queryReply(args, timeout: timeout)
    guard case .exited(0, _) = read.reply else { return nil }
    return read.value
}

/// What yabai says about window `id`, or why it said nothing usable.
@Sendable func windowQuery(_ id: Int) -> (info: [String: Any]?, why: String?, untracked: Bool) {
    let what = "yabai -m query --windows --window \(id)"
    let read = queryReply(["query", "--windows", "--window", String(id)])
    switch read.reply {
    case .exited(0, _):
        if let w = read.value as? [String: Any] { return (w, nil, false) }
        return (nil, "\(what) answered unreadably", false)
    case .exited(let code, let data):
        let untracked = code == 1 && String(decoding: data, as: UTF8.self).contains("could not locate window with the specified id")
        return (nil, "\(what) exited \(code)", untracked)
    case .timedOut(let allowed): return (nil, "\(what) did not answer within \(String(format: "%.1f", allowed)) s", false)
    case .refused(let why): return (nil, why, false)
    }
}

/// The Space shown on Tim's display (the one holding Space 1), from `yabai -m query --spaces`.
@Sendable func timDisplaySpace(_ spaces: Any?) -> Int? {
    guard let spaces = spaces as? [[String: Any]],
          let display = spaces.first(where: { ($0["index"] as? NSNumber)?.intValue == 1 })?["display"] as? NSNumber else { return nil }
    let shown = spaces.first { ($0["display"] as? NSNumber) == display && $0["is-visible"] as? Bool == true }
    return (shown?["index"] as? NSNumber)?.intValue
}

/// GR2 item 6: from `yabai -m query --spaces`, Tim's display (the one holding Space 1) and the focused display (the
/// one holding the Space with focus; nil: no row has focus), by yabai's display index.
@Sendable func displays(_ spaces: Any?) -> (tims: Int?, focused: Int?) {
    guard let spaces = spaces as? [[String: Any]] else { return (nil, nil) }
    let tims = spaces.first(where: { ($0["index"] as? NSNumber)?.intValue == 1 })?["display"] as? NSNumber
    let focused = spaces.first(where: { $0["has-focus"] as? Bool == true })?["display"] as? NSNumber
    return (tims?.intValue, focused?.intValue)
}

func windowFields(_ w: [String: Any]?) -> [String: Any] {
    ["window": w?["id"] ?? NSNull(), "windowPid": w?["pid"] ?? NSNull(), "windowApp": w?["app"] ?? NSNull()]
}

// MARK: - Windows (yabaiQueue; the final sweep on endQueue)

@Sendable func recordWindowFault(_ record: [String: Any]) {
    windowFaults.update { $0.append(record) }
    emit(record)
}

/// GR2: how often, and for how long after the event that reported it, a tree window yabai will not place (no answer,
/// or one without its owner or Space) is asked about again; it is moved as soon as yabai places it. perf's receipt
/// (af721a36, 06:30Z): Accessibility reported windows yabai did not list yet, the guard gave up after 1 s, and one sat
/// on Tim's Space 4 unmoved for ~10 s while the check said ok.
let unplacedInterval = 0.05
let unplacedLimit = 3.0
/// GR2: the longest a tree window may be on Tim's screen before the guard moves it: longer is a problem. The GR1
/// receipts parked new windows in 30-95 ms; perf's late-listed ones took 769-1,279 ms.
let onTimsScreenLimit = 0.25

/// GR2: where SkyLight puts a window, read directly (no yabai): its Spaces (SkyLight ids; none: on no Space, so
/// ordered out, or gone) and its display's identifier.
struct WindowPlace {
    let spaces: [UInt64]
    let display: String?
}

/// GR2: WindowServer's record of a window, which needs no yabai: its owner (pid, and its name: GR2 item 6, for system
/// modals), whether it is on screen (kCGWindowIsOnscreen, recorded only: it is false for a window ordered in on a
/// Space no display shows, too) and its bounds. A nil field: unreadable.
struct ServerWindow {
    let id: Int
    let pid: pid_t?
    let onScreen: Bool?
    let bounds: CGRect?
    let owner: String?
}

/// One row of CGWindowListCopyWindowInfo; nil: one without its number.
@Sendable func serverWindow(_ row: [String: Any]) -> ServerWindow? {
    guard let id = (row[kCGWindowNumber as String] as? NSNumber)?.intValue else { return nil }
    let bounds = (row[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
    return ServerWindow(id: id, pid: (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                        onScreen: (row[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue, bounds: bounds,
                        owner: row[kCGWindowOwnerName as String] as? String)
}

/// The rig's stand-in for WindowServer (--onscreen): rows `[id, pid]`, `[id, pid, width, height]`, `[id, pid, width,
/// height, onScreen]` or `[id, pid, width, height, onScreen, owner name]` (a width or height null: bounds unreadable;
/// no onScreen: true). A window listed exists; one not listed is gone. nil: the file is unreadable.
@Sendable func rigServerWindows() -> [ServerWindow]? {
    guard let onscreenPath, let data = try? Data(contentsOf: URL(fileURLWithPath: onscreenPath)),
          let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[Any]] else { return nil }
    return rows.compactMap { row -> ServerWindow? in
        guard row.count >= 2, let id = (row[0] as? NSNumber)?.intValue, let pid = (row[1] as? NSNumber)?.int32Value else { return nil }
        let width = row.count >= 4 ? (row[2] as? NSNumber)?.doubleValue : nil
        let height = row.count >= 4 ? (row[3] as? NSNumber)?.doubleValue : nil
        let bounds = width.flatMap { w in height.map { h in CGRect(x: 0, y: 0, width: w, height: h) } }
        let onScreen: Bool? = row.count >= 5 ? row[4] as? Bool : true
        return ServerWindow(id: id, pid: pid, onScreen: onScreen, bounds: bounds, owner: row.count >= 6 ? row[5] as? String : nil)
    }
}

/// WindowServer's record of window `id` (`exists` false: it has none, the window is gone); nil: unreadable. The rig
/// reads its stand-in (rigServerWindows; without one, nil).
@Sendable func windowServerState(_ id: Int) -> (exists: Bool, window: ServerWindow?)? {
    if rigTest {
        guard onscreenPath != nil, let rows = rigServerWindows() else { return nil }
        let row = rows.first { $0.id == id }
        return (row != nil, row)
    }
    guard let rows = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(id)) as? [[String: Any]] else { return nil }
    guard let row = rows.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.intValue == id }) else { return (false, nil) }
    return (true, serverWindow(row))
}

/// Native location alone is not placement; the separately recorded proof below never excuses a query timeout.
let nativeWindows = Locked([Int: [String: Any]]())
let nativePlacements = Locked([Int: [String: Any]]())

/// WindowServer's windows: every one, on hidden Spaces too, or only the ones on screen now (every display's current
/// Space); nil: unreadable. The rig reads its stand-in (rigServerWindows; the on-screen ones are the rows not marked
/// off screen), and without one has none.
@Sendable func serverWindows(onScreenOnly: Bool) -> [ServerWindow]? {
    if rigTest {
        guard onscreenPath != nil else { return [] }
        return rigServerWindows()?.filter { !onScreenOnly || $0.onScreen != false }
    }
    let options: CGWindowListOption = onScreenOnly ? [.optionOnScreenOnly, .excludeDesktopElements] : [.optionAll, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }
    return list.compactMap(serverWindow)
}

/// A per-window record map, as the summary's list in window order.
func byWindow(_ rows: [Int: [String: Any]]) -> [[String: Any]] {
    rows.sorted { $0.key < $1.key }.map { $0.value }
}

@Sendable func boundsField(_ bounds: CGRect?) -> Any {
    bounds.map { [Double($0.origin.x), Double($0.origin.y), Double($0.width), Double($0.height)] } ?? NSNull()
}

/// Keeps the latest native proof and emits the first record for each window/owner pair.
@Sendable func recordNative(_ row: [String: Any], id: Int, pid: pid_t, in records: Locked<[Int: [String: Any]]>) {
    let first = records.update { (rows: inout [Int: [String: Any]]) -> Bool in
        let first = (rows[id]?["pid"] as? Int) != Int(pid)
        rows[id] = row
        return first
    }
    if first { emit(row) }
}

/// A native owner is vouched for against the tree's current pid/start identity (the caller's) before its window is
/// enrolled here: the first record of each (window, pid) is emitted.
@Sendable func locateNative(_ w: ServerWindow, pid: pid_t, via: String) {
    let row: [String: Any] = ["event": "window-native-located", "source": "CGWindowList", "window": w.id,
                             "pid": Int(pid), "app": w.owner ?? "", "bounds": boundsField(w.bounds),
                             "onScreen": w.onScreen ?? NSNull(), "via": via]
    recordNative(row, id: w.id, pid: pid, in: nativeWindows)
}

/// GR2 (bench's ruling, GR1 addendum 4 note 3): one sample of a tree window, read directly, no yabai: WindowServer's
/// record (nil: unreadable; `exists` false: gone) and SkyLight's place (nil: unreadable). Any thread; no child process.
struct WindowLook {
    let server: (exists: Bool, window: ServerWindow?)?
    let place: WindowPlace?

    init(_ id: Int, server given: ServerWindow? = nil) {
        server = given.map { (exists: true, window: $0) } ?? windowServerState(id)
        place = SkyLight.windowPlace(id)
    }

    var gone: Bool { server?.exists == false }

    /// Why the window is exempt, no window of Tim's screen wherever it is: WindowServer's bounds of it are 2×2 px or
    /// less (width and height both), or WindowServer has it and SkyLight puts it on no Space (ordered out). nil: it
    /// counts, and so does one whose state, Spaces or bounds cannot be read. kCGWindowIsOnscreen is no test: a window
    /// ordered in on a Space no display shows is off screen too, and counts.
    var exempt: String? {
        guard server?.exists == true, let bounds = server?.window?.bounds, let place else { return nil }
        if bounds.width <= 2, bounds.height <= 2 { return "2x2 px or less" }
        if place.spaces.isEmpty { return "ordered out" }
        return nil
    }

    /// Whether SkyLight puts the window on Tim's screen (any of its Spaces is; SpaceWatch.showsTim). nil: it cannot
    /// say: unreadable, or on no Space for a window not shown to exist (ordered out is exempt; gone, or WindowServer
    /// unreadable, proves nothing).
    var spaceOnTims: Bool? {
        guard server?.exists == true, server?.window?.bounds != nil, let place, !place.spaces.isEmpty else { return nil }
        return place.spaces.contains { spaceWatch.showsTim(spaceId: $0) }
    }

    /// Whether the window is on Tim's screen at this sample: it counts, and SkyLight puts it on one of his Spaces or
    /// cannot say where it is.
    var onTims: Bool { exempt == nil && spaceOnTims != false }
    /// The Tim membership named by a counted sample, for diagnostics; unreadable samples count but cannot name it.
    var timLocation: String {
        if let sid = place?.spaces.first(where: { spaceWatch.showsTim(spaceId: $0) }) {
            if let index = spaceWatch.index(of: sid) { return "Tim's Space \(index)" }
            return "Tim's screen (SkyLight Space \(sid))"
        }
        return "Tim's screen (window state, membership or bounds unreadable)"
    }

    /// The sample, for a record: WindowServer's owner, bounds ([x, y, width, height]) and on-screen flag; SkyLight's
    /// ordered state ("in": on a Space; "out": on none), Spaces (yabai's indexes, null for one its map does not know;
    /// spaceIds, SkyLight's) and display. null: unreadable.
    var fields: [String: Any] {
        let w = server?.window
        var record: [String: Any] = ["pid": NSNull(), "bounds": boundsField(w?.bounds), "onScreen": w?.onScreen ?? NSNull(), "ordered": NSNull(),
                                     "spaces": NSNull(), "spaceIds": NSNull(), "display": place?.display ?? NSNull()]
        if let pid = w?.pid { record["pid"] = Int(pid) }
        if let place {
            record["ordered"] = place.spaces.isEmpty ? "out" : "in"
            record["spaceIds"] = place.spaces.map { NSNumber(value: $0) }
            record["spaces"] = place.spaces.map { (sid: UInt64) -> Any in spaceWatch.index(of: sid) ?? NSNull() }
        }
        return record
    }
}

/// The wrapper's post-exit exemption check needs fresh measured proof, not the earlier final exemption. No AppKit
/// loop, activation or yabai command: raw WindowServer presence/owner/bounds and every SkyLight membership. The rig
/// uses the same WindowLook adapter. No SpaceWatch is initialized here, so these are raw SkyLight IDs.
func readWindowLooks(_ ids: [Int]) -> Never {
    var rows: [String: Any] = [:]
    for id in ids {
        let look = WindowLook(id)
        let w = look.server?.window
        let bounds: Any = w?.bounds.map { [$0.origin.x, $0.origin.y, $0.width, $0.height].map { Double($0) } } ?? NSNull()
        let spaceIds: Any = look.place.map { $0.spaces.map { NSNumber(value: $0) } } ?? NSNull()
        rows[String(id)] = ["exists": look.server.map { $0.exists as Any } ?? NSNull(), "pid": w?.pid.map { Int($0) } ?? NSNull(),
                            "bounds": bounds, "spaceIds": spaceIds]
    }
    writeLine(rows)
    exit(0)
}

/// A tree window's first sighting by Accessibility, WindowServer or a yabai list: when, SkyLight's place, why
/// it was exempt then (WindowLook.exempt; nil: it counted), and whether it was on Tim's screen (false: exempt, or
/// elsewhere; nil: SkyLight could not say, which counts as on it).
struct FirstSighting {
    let at: Double
    let place: WindowPlace?
    let exempt: String?
    let onTims: Bool?
}
let firstSightings = Locked([Int: FirstSighting]())

/// The tree windows unplaced at a sample and not placed since (unplacedAt; the resolution event, window-located, takes
/// one window-unknown recorded out): when the event that reported each came, what reported it, why yabai would not
/// place it, whether every read of it so far showed it off Tim's screen, and whether window-unknown recorded it.
typealias Unresolved = (seen: Double, via: String, why: String, offTims: Bool, reported: Bool)
let unresolved = Locked([Int: Unresolved]())

/// The tree windows exempt at their last sample, enrolled and recorded at first sighting before any yabai query.
/// The windows-on-screen poll samples each again; one that counts then is parked, judged from that first counting sample.
let exemptNow = Locked([Int: Double]())
/// The window-exempt records (the summary's exemptWindows): the first sample of each exempt stretch, and the final
/// sweep's.
let exemptRecords = Locked([[String: Any]]())
/// The stretch each tree window has counted in, unbroken by an exempt sample: since when (uptime), and whether it was
/// on Tim's screen then (false: not known before yabai's answer).
let countingSince = Locked([Int: (at: Double, onTims: Bool)]())
/// Review 4: the tree windows the end's last read of the windows on screen (ShownWindows.finalPass) found on Tim's
/// screen, a problem reported then, before the final sweep's window list: the final sweep reports no more of them.
let endReported = Locked(Set<Int>())

/// A tree window was reported at `seen` (`via`): its first direct sample, before queued yabai work. An exempt sample
/// is recorded and enrolled for the 100 ms resampler immediately. `given`: that sample, already taken (review 6: the
/// end's final pass judges the same one); nil: one is taken here. True: this was the window's first sighting. Any
/// thread; no child process.
@discardableResult
@Sendable func sighted(_ id: Int, at seen: Double, via: String, look given: WindowLook? = nil) -> Bool {
    guard firstSightings.value[id] == nil else { return false }
    let look = given ?? WindowLook(id)
    let exempt = look.exempt
    let sighting = FirstSighting(at: seen, place: look.place, exempt: exempt, onTims: exempt != nil ? false : look.spaceOnTims)
    let fresh = firstSightings.update { (all: inout [Int: FirstSighting]) -> Bool in
        guard all[id] == nil else { return false }
        all[id] = sighting
        return true
    }
    if fresh, let exempt {
        exempted(id, look, at: seen, reason: exempt, via: via, found: nil, why: "yabai not queried at first sighting", final: false)
    }
    return fresh
}

/// The first-sighting fields of window `id`'s records: firstAt (seconds since launch), firstSpace (its index; null:
/// one yabai's map does not know, or none), firstSpaceId, firstDisplay, firstExempt and firstOnTimsScreen. None
/// before a sighting.
@Sendable func firstFields(_ id: Int) -> [String: Any] {
    guard let first = firstSightings.value[id] else { return [:] }
    let sid = first.place?.spaces.first
    return ["firstAt": decimal(first.at - t0, 3), "firstSpace": sid.flatMap { spaceWatch.index(of: $0) } ?? NSNull(),
            "firstSpaceId": sid.map { NSNumber(value: $0) } ?? NSNull(), "firstDisplay": first.place?.display ?? NSNull(),
            "firstExempt": first.exempt ?? NSNull(), "firstOnTimsScreen": first.onTims ?? NSNull()]
}

/// A sample (`look`, taken at `sampled`) found tree window `id` exempt (`reason`): it is recorded (window-exempt, at
/// the first sample of each exempt stretch and at the final sweep), never moved, never a problem, and not unknown;
/// it counts again only from a sample that finds it so. `found`: yabai's answer about it (nil: none, `why`). The
/// stretch it counted in until now is judged first, if no placement judged it: one that began on Tim's screen
/// (countingSince) of a window yabai never placed was there for up to `sampled` minus its start, a problem past
/// onTimsScreenLimit (fail closed: no sample between bounds it tighter).
@Sendable func exempted(_ id: Int, _ look: WindowLook, at sampled: Double, reason: String, via: String, found: [String: Any]?,
                        why: String?, final: Bool) {
    let fresh = exemptNow.update { (now: inout [Int: Double]) -> Bool in
        defer { now[id] = sampled }
        return now[id] == nil
    }
    let stretch = countingSince.update { $0.removeValue(forKey: id) }
    if let stretch, stretch.onTims, windowSpaces.value[id] == nil, sampled - stretch.at > onTimsScreenLimit {
        let pid = look.server?.window?.pid.map { "pid \($0)" } ?? "pid unknown"
        problem(String(format: "window %ld of the tree (%@) counted on Tim's screen for up to %.1f ms, never placed, until a sample found it exempt (%@) (more than %.0f ms)",
                       id, pid, (sampled - stretch.at) * 1000, reason, onTimsScreenLimit * 1000))
    }
    windowsUnknown.update { $0[id] = nil }
    guard fresh || final else { return }
    var record = look.fields
    record["event"] = "window-exempt"
    record["window"] = id
    record["reason"] = reason
    record["via"] = via
    record["final"] = final
    record["yabai"] = found.map { ["space": $0["space"] ?? NSNull(), "pid": $0["pid"] ?? NSNull()] as [String: Any] }
        ?? ["error": why ?? "yabai said nothing about window \(id)"]
    exemptRecords.update { $0.append(record) }
    emit(record)
}

/// A sample taken at `sampled` (for the event at `seen`) found tree window `id` counting: the stretch it counts in. One
/// that counted at its first sighting and was never exempt since counts from that sighting; one that was exempt (at
/// its first sighting or a sample since) counts from this sample (bench's ruling: judged from that sample on), or from
/// the poll's sample that found it counting (ShownWindows); one never sighted counts from `seen`.
@Sendable func counting(_ id: Int, at sampled: Double, seen: Double) -> (at: Double, onTims: Bool) {
    let wasExempt = exemptNow.update { $0.removeValue(forKey: id) } != nil
    let first = firstSightings.value[id]
    return countingSince.update { (since: inout [Int: (at: Double, onTims: Bool)]) -> (at: Double, onTims: Bool) in
        if !wasExempt, let stretch = since[id] { return stretch }
        let stretch: (at: Double, onTims: Bool)
        if wasExempt || first?.exempt != nil {
            stretch = (sampled, false)
        } else if let first {
            stretch = (first.at, first.onTims != false)
        } else {
            stretch = (seen, false)
        }
        since[id] = stretch
        return stretch
    }
}

/// Tree window `id` was unplaced at a sample (`look`): unresolved from then until yabai places it (the end reports
/// one never placed, even if the guard ended within the 3 s it is asked about), from the event that reported it
/// (`seen`, `via`); `reported` once window-unknown records it. Off Tim's screen only while its first sighting, every
/// counted sample since (the stretch it counts in, countingSince: a sample that found it counting on his screen after
/// an exempt one stays evidence after it closes) and this sample showed it off. `excusable` false: the reason is a
/// native state no off-Tim sample excuses (an unmapped membership, the assigned Space on Tim's display): the end
/// reports the window unless it is placed, however it was sampled.
@Sendable func unplacedAt(_ id: Int, _ look: WindowLook, seen: Double, via: String, why: String, reported: Bool, excusable: Bool = true) {
    let countedOnTims = countingSince.value[id]?.onTims == true
    let off = excusable && firstSightings.value[id]?.onTims == false && !countedOnTims && (look.gone || !look.onTims)
    unresolved.update { (list: inout [Int: Unresolved]) -> Void in
        let known = list[id]
        list[id] = (seen: known?.seen ?? seen, via: known?.via ?? via, why: why, offTims: (known?.offTims ?? true) && off,
                    reported: reported || known?.reported == true)
    }
}

/// yabai would not place tree window `id` (`why`) for unplacedLimit since the event that reported it (`seen`), or at
/// the final sweep: window-unknown, with what WindowServer and SkyLight show of it now. It is unresolved until yabai
/// places it (window-located); unless WindowServer shows it gone it stays unknown, which the end reports.
@Sendable func windowUnknown(_ id: Int, seen: Double, via: String, why: String, excusable: Bool = true) {
    let look = WindowLook(id)
    let now = look.place
    windowsUnknown.update { $0[id] = look.gone ? nil : why }
    unplacedAt(id, look, seen: seen, via: via, why: why, reported: true, excusable: excusable)
    let shown: Any = look.server.map { (state: (exists: Bool, window: ServerWindow?)) -> String in
        guard state.exists else { return "gone" }
        switch state.window?.onScreen {
        case true?: return "on screen"
        case false?: return "off screen"
        case nil: return "present"
        }
    } ?? NSNull()
    recordWindowFault(firstFields(id).merging([
        "event": "window-unknown", "window": id, "via": via, "reason": why, "windowServer": shown,
        "bounds": look.fields["bounds"] ?? NSNull(), "unplacedMs": ms(uptime() - seen),
        "space": now?.spaces.first.flatMap { spaceWatch.index(of: $0) } ?? NSNull(),
        "spaceId": now?.spaces.first.map { NSNumber(value: $0) } ?? NSNull(), "display": now?.display ?? NSNull(),
    ]) { $1 })
}

/// At the guard's end (after the final sweep): each tree window still unknown, or unresolved and gone, is a problem,
/// unless every read of it showed it off Tim's screen (it was never his to see): its time on his screen cannot be
/// bounded. The end's own sample of one still unknown counts too. Review 3: so is every stretch a window yabai never
/// placed counted in on Tim's screen (countingSince) that no park or exempt sample judged, as when the guard's end
/// skipped the park its counting sample queued (the window grown and gone by then): on his screen, as far as the guard
/// knows, until now, a problem past onTimsScreenLimit (fail closed). Review 4: an unresolved entry is no proof that such
/// a stretch was judged (its park may be the one skipped): every one is merged into the window's unresolved entry
/// first, so an entry whose earlier reads all showed it off Tim's screen is on it after all.
@Sendable func reportUnplacedAtEnd() {
    let unknown = windowsUnknown.value
    var open = unresolved.value
    let placed = windowSpaces.value
    let counted = countingSince.value.filter { $0.value.onTims && placed[$0.key] == nil }
    var merged = Set<Int>()
    for id in counted.keys where open[id]?.offTims == true {
        open[id]?.offTims = false
        merged.insert(id)
    }
    for id in unknown.keys where open[id] != nil && WindowLook(id).onTims {
        open[id]?.offTims = false  // on his screen, or SkyLight names no place for it
    }
    for (id, why) in unknown.sorted(by: { $0.key < $1.key }) where open[id]?.offTims != true {
        problem("window \(id) of the tree could not be located at the guard's end: \(why)")
    }
    for (id, u) in open.sorted(by: { $0.key < $1.key }) where unknown[id] == nil && !u.offTims {
        let evidence = merged.contains(id) ? "a sample counted it on Tim's screen after reads that showed it off" : "nothing showed it off Tim's screen"
        problem("window \(id) of the tree (reported by \(u.via)) was never placed before it went: \(u.why); \(evidence), so its time there cannot be bounded")
    }
    let end = uptime()
    for (id, stretch) in counted.sorted(by: { $0.key < $1.key })
        where unknown[id] == nil && open[id] == nil && end - stretch.at > onTimsScreenLimit {
        problem(String(format: "window %ld of the tree counted on Tim's screen for up to %.1f ms, never placed, and no sample judged it before the guard's end (more than %.0f ms)",
                       id, (end - stretch.at) * 1000, onTimsScreenLimit * 1000))
    }
}

/// A window list failed: where the tree's windows are is unknown until one answers.
@Sendable func windowListFailed(via: String, why: String) {
    windowListFailure.update { $0 = why }
    recordWindowFault(["event": "window-list-failed", "via": via, "reason": why])
}

/// Shared Tim-Space facts; callers decide whether the assigned Space is exempt and which display facts apply.
@Sendable func timMembership(_ index: Int, shown: @autoclosure () -> Bool, expected: @autoclosure () -> Bool = false) -> Bool {
    timSpaces.contains(index) || shown() || expected()
}

/// GR2: whether a tree window on Space `s` is on Tim's screen: on one of his Spaces (1-4), or on the Space his display
/// shows (as last read) or should show, unless that is --space itself (he went there himself). Any thread.
@Sendable func onTimsScreen(_ s: Int) -> Bool {
    guard s != space else { return false }
    return timMembership(s, shown: s == spaceWatch.shownIndex, expected: s == spacePolicy.value.expected)
}

/// Tree window `w` (`id`) is on Space `at`, not --space, and was not moved there: a problem (GR2, addendum 1), unless
/// the caller declared that it places the tree's windows itself (--allow-caller-placement) and the window is on a
/// Space and off Tim's screen. The fault is recorded either way, with whether it was excused.
@Sendable func windowOffTarget(_ id: Int, _ w: [String: Any], at: Int, look: WindowLook, via: String, why: String) {
    let excused = allowCallerPlacement && at != 0 && !look.onTims
    recordWindowFault(["event": "window-off-target", "window": id, "pid": w["pid"] ?? NSNull(), "app": w["app"] ?? "",
                       "space": at, "target": space, "via": via, "reason": why,
                       "excused": excused ? "caller placement" as Any : NSNull()])
    if !excused {
        let pid = (w["pid"] as? NSNumber).map { "pid \($0)" } ?? "pid unknown"
        let place = at == 0 ? "on no Space" : look.onTims ? "on \(look.timLocation)" : "on Space \(at)"
        problem("window \(id) of the tree (\(w["app"] as? String ?? "?"), \(pid)) is \(place), not on --space \(space), after the guard's move (\(via)): \(why)")
    }
}

/// Tree window `id` (`window`, owned by tree process `pid`) is untracked by yabai, and `look` shows it on the assigned
/// Space and on no Tim Space or Tim-visible Space: placed-native (CGWindowList ownership and bounds, SkyLight
/// membership), a current proof and no move, no yabai row and no yabai answer. It clears the window's unknown state
/// and unresolved entry, and counts as its placement for the end; the exposure it counted on Tim's screen before this
/// first placement is judged as a yabai placement's is (slowPlacement), unless `quiet` (already reported). It excuses
/// no query timeout: park only calls it for an untracked answer.
@Sendable func placedNative(_ id: Int, _ window: ServerWindow, pid: pid_t, look: WindowLook, stretch: (at: Double, onTims: Bool),
                            queried: Double, via: String, quiet: Bool) {
    let app = window.owner ?? "?"
    windowsUnknown.update { $0[id] = nil }
    let before = windowSpaces.update { (spaces: inout [Int: Int]) -> Int? in
        defer { spaces[id] = space }
        return spaces[id]
    }
    windowOnTims.update { $0[id] = false }
    let resolved = unresolved.update { $0.removeValue(forKey: id) }
    let exposed = before == nil && stretch.onTims ? queried - stretch.at : nil
    if let exposed, !quiet { slowPlacement(id, app: app, pid: pid, seconds: exposed) }
    var placed = firstFields(id).merging(look.fields) { $1 }
    placed.merge(["event": "placed-native", "window": id, "pid": Int(pid), "app": app, "space": space,
                  "source": "CGWindowList+SkyLight", "placement": "placed-native (untracked by yabai)",
                  "via": via, "at": decimal(queried - t0, 3)]) { $1 }
    if let resolved { placed["unknownMs"] = ms(queried - resolved.seen) }
    if let exposed { placed["onTimSpaceMs"] = ms(exposed) }
    recordNative(placed, id: id, pid: pid, in: nativePlacements)
}

/// Tree window `id` counted on Tim's screen for `seconds` before its first placement (or, if it is elsewhere now,
/// until the sample that found it so): a problem past onTimsScreenLimit.
@Sendable func slowPlacement(_ id: Int, app: String, pid: pid_t, seconds: Double) {
    guard seconds > onTimsScreenLimit else { return }
    problem(String(format: "window %ld of the tree (%@, pid %d) was on Tim's screen for %.1f ms before the guard placed it (more than %.0f ms)",
                   id, app, pid, seconds * 1000, onTimsScreenLimit * 1000))
}

/// Native discovery cannot hold up AX/shown parks; both lanes share one in-flight owner of each window id.
let parkingWindows = Locked(Set<Int>())

/// Moves one tree window to the target Space by id, after checking yabai knows it and that it is the tree's (its
/// pid, with the start time the tree recorded). `seen` is when the event that reported it arrived; yabai may
/// learn of a brand-new window some time after Accessibility does, so a window yabai will not place is asked about
/// again every unplacedInterval until unplacedLimit after `seen` (GR2; was 1 s), without holding up the queue, and
/// moved as soon as yabai places it. Nothing ends unrecorded: from its first failure it is unknown (the end reports
/// it if nothing places it), and at the limit it is window-unknown and unresolved until yabai places it
/// (window-located); only an answer naming an owner outside the tree, a placement, an exempt sample, or WindowServer
/// showing it gone clears its unknown state. A tree window still off the target after its move (or on no Space, which
/// a move by Space cannot reach) is window-off-target. GR2 (bench's ruling): each park samples the window directly
/// (WindowLook); an exempt one (ordered out, or 2×2 px or less) is recorded (window-exempt), never moved, never a
/// problem, and no retry is made: the windows-on-screen poll samples it again. Each counted sighting's yabai index
/// and measured Tim membership are kept (windowSpaces, windowOnTims); all memberships count, not only yabai's index.
/// A window back on Tim's screen after an off-Tim sample, or there at the final sweep, is a problem, created or not. Its
/// first placement on his screen is a move whose onTimSpaceMs counts from the start of the stretch it has counted in
/// (its first sighting, the sample that found it counting after an exempt one, or the event that reported it) to the
/// move: a problem past onTimsScreenLimit; so is a window that stretch began on his screen (SkyLight) that yabai places
/// elsewhere later than that. An id yabai says it never tracked is placed-native (placedNative) only when WindowServer
/// and SkyLight prove it on the assigned Space and on no Tim Space; an unmapped membership or the assigned Space on
/// Tim's display is unplaced (retried, and reported at the end unless placed). `latched`: the sweep already reported
/// this window's sample on his screen (omittedSample), so this park reports nothing more of that exposure.
/// `native`: discoveries and their retries stay off the foreground AX/shown queue.
func park(_ id: Int, seen: Double, via: String, final: Bool = false, latched: Bool = false, native: Bool = false) {
    tracked("park of window \(id) (\(via))", final: final) {
        guard parkingWindows.update({ $0.insert(id).inserted }) else { return }
        defer { _ = parkingWindows.update { $0.remove(id) } }
        let query = windowQuery(id)
        let found = query.info
        let why = query.why
        let queried = uptime()
        if let owner = (found?["pid"] as? NSNumber)?.int32Value, !tree.contains(owner) {
            windowsUnknown.update { $0[id] = nil }
            unresolved.update { $0[id] = nil }
            countingSince.update { $0[id] = nil }  // not the tree's: no evidence of it (review 3)
            return
        }
        let look = WindowLook(id)
        if let reason = look.exempt {
            return exempted(id, look, at: queried, reason: reason, via: via, found: found, why: why, final: final)
        }
        let stretch = counting(id, at: queried, seen: seen)
        let quiet = latched || (final && endReported.value.contains(id))  // reported already (review 4: the end's last read)
        func unplaced(_ why: String, excusable: Bool = true) {
            windowsUnknown.update { $0[id] = why }
            if !final && uptime() - seen < unplacedLimit {
                unplacedAt(id, look, seen: seen, via: via, why: why, reported: false, excusable: excusable)
                let queue = native ? nativeParkQueue : yabaiQueue
                queue.asyncAfter(deadline: .now() + unplacedInterval) { park(id, seen: seen, via: via, native: native) }
            } else {
                windowUnknown(id, seen: seen, via: via, why: why, excusable: excusable)
            }
        }
        // yabai says it never tracked the window: WindowServer and SkyLight may still place it. Only a window proven on
        // the assigned Space and on no Tim Space is placed; a membership yabai's map cannot name (asked again: its map
        // is read afresh) or the assigned Space on Tim's display is unplaced like any other reason, and the end reports
        // it unless a later sample places it, whatever a sample of it showed off Tim's screen.
        if query.untracked, let window = look.server?.window, let owner = window.pid, tree.contains(owner) {
            locateNative(window, pid: owner, via: via)
            let placement = look.place.map { spaceWatch.placementOnAgent($0.spaces) } ?? .unknown
            switch placement {
            case .assigned where !look.onTims:
                return placedNative(id, window, pid: owner, look: look, stretch: stretch, queried: queried, via: via, quiet: quiet)
            case .unknown where look.place?.spaces.isEmpty == false:
                spaceWatch.mapMissed()
                return unplaced("window \(id) of the tree has native Space membership yabai cannot map: placement is unknown", excusable: false)
            case .onTims where !look.onTims:
                return unplaced("window \(id) of the tree is untracked by yabai and on Tim's currently visible assigned Space: not placed-native", excusable: false)
            default:
                break
            }
        }
        guard let w = found else { return unplaced(why ?? "yabai said nothing about window \(id)") }
        guard let pid = (w["pid"] as? NSNumber)?.int32Value else {
            return unplaced("yabai's answer about window \(id) does not say whose it is")
        }
        guard let from = (w["space"] as? NSNumber)?.intValue else {
            return unplaced("yabai's answer about window \(id) gives no Space")
        }
        windowsUnknown.update { $0[id] = nil }
        let app = w["app"] as? String ?? "?"
        let before = windowSpaces.update { (spaces: inout [Int: Int]) -> Int? in
            defer { spaces[id] = from }
            return spaces[id]
        }
        let onTims = look.onTims
        let wasOnTims = windowOnTims.update { (samples: inout [Int: Bool]) -> Bool? in
            defer { samples[id] = onTims }
            return samples[id]
        }
        let back = onTims && wasOnTims == false
        let flagged = quiet || back || (onTims && final)
        if flagged && !quiet {
            problem(back ? "window \(id) of the tree (\(app), pid \(pid)) was on \(look.timLocation) (found by \(via)) after the guard had seen it on Space \(before.map { String($0) } ?? "?"): macOS showed it to him again"
                         : "window \(id) of the tree (\(app), pid \(pid)) was on \(look.timLocation) at the guard's end")
        }
        // On Tim's screen before this first placement, for how long (until the move, or, if it is elsewhere now, until now).
        func slow(_ seconds: Double) {
            guard !flagged else { return }
            slowPlacement(id, app: app, pid: pid, seconds: seconds)
        }
        let start = stretch.at
        let leftUnseen = before == nil && !onTims && stretch.onTims ? queried - start : nil
        let resolved = unresolved.update { $0.removeValue(forKey: id) }
        if let resolved, resolved.reported {
            var located: [String: Any] = firstFields(id).merging([
                "event": "window-located", "window": id, "pid": Int(pid), "app": app, "space": from, "via": via,
                "unknownMs": ms(queried - resolved.seen),
            ]) { $1 }
            if let leftUnseen { located["onTimSpaceMs"] = ms(leftUnseen) }
            emit(located)
        }
        if let leftUnseen { slow(leftUnseen) }
        if from == space && !onTims { return }
        if from == 0 {
            windowOffTarget(id, w, at: 0, look: look, via: via, why: "yabai places it on no Space, where a move by Space cannot reach it")
            return
        }
        let move = yabaiReply(["window", String(id), "--space", String(space)])
        let (moved, afterWhy, _) = windowQuery(id)
        let after = (moved?["space"] as? NSNumber)?.intValue
        let afterLook = WindowLook(id)
        let done = uptime()
        var record: [String: Any] = firstFields(id).merging([
            "event": "window", "id": id, "pid": Int(pid), "app": w["app"] ?? "", "title": w["title"] ?? "",
            "subrole": w["subrole"] ?? "", "from": from, "to": after ?? NSNull(), "moved": after == space, "via": via,
            "latencyMs": ms(done - seen),
        ]) { $1 }
        if onTims {
            let exposure = done - (before == nil ? start : seen)
            record["onTimSpaceMs"] = ms(exposure)
            if before == nil { slow(exposure) }
        }
        if back, let before { record["seenBefore"] = before }
        if let after { windowSpaces.update { $0[id] = after } }
        windowOnTims.update { $0[id] = afterLook.onTims }
        moves.update { $0.append(record) }
        emit(record)
        guard let after else {
            windowUnknown(id, seen: seen, via: via, why: afterWhy ?? "yabai's answer about window \(id) gives no Space")
            return
        }
        if after == space {
            if afterLook.onTims && !flagged {
                problem("window \(id) of the tree (\(app), pid \(pid)) is still on \(afterLook.timLocation) after the guard's move (\(via)), though yabai reports --space \(space)")
            }
            return
        }
        let what = "yabai -m window \(id) --space \(space)"
        let reason: String
        switch move {
        case .exited(0, _): reason = "\(what) succeeded, yet the window is on Space \(after)"
        case .exited(let code, _): reason = "\(what) exited \(code)"
        case .timedOut(let allowed): reason = "\(what) did not answer within \(String(format: "%.1f", allowed)) s"
        case .refused(let why): reason = why
        }
        windowOffTarget(id, w, at: after, look: afterLook, via: via, why: reason)
    }
}

/// The final sweep's logical query record: attempts include their cleanup and share the ordinary 4 s bound.
let finalWindowList = Locked([String: Any]())

/// One read of yabai's window list: each window's id, pid and Space; or why it could not be read (a list that
/// fails, runs out of time, or has a row without an id or pid). Only the final sweep owns timeout adjudication.
@Sendable func windowList(ownsTimeout: Bool = false, until: Double? = nil) -> (windows: [(id: Int, pid: pid_t, space: Int?)]?, why: String?, record: [String: Any]) {
    let what = "yabai -m query --windows"
    let list: [[String: Any]]
    let query = queryReply(["query", "--windows"], ownsTimeout: ownsTimeout, until: until)
    switch query.reply {
    case .exited(0, _):
        guard let rows = query.value as? [[String: Any]] else { return (nil, "\(what) answered unreadably", query.record) }
        list = rows
    case .exited(let code, _): return (nil, "\(what) exited \(code)", query.record)
    case .timedOut(let allowed): return (nil, "\(what) did not answer within \(String(format: "%.1f", allowed)) s", query.record)
    case .refused(let why): return (nil, why, query.record)
    }
    var windows: [(id: Int, pid: pid_t, space: Int?)] = []
    for row in list {
        guard let id = (row["id"] as? NSNumber)?.intValue, let pid = (row["pid"] as? NSNumber)?.int32Value else {
            return (nil, "\(what) answered a row without an id or pid", query.record)
        }
        windows.append((id, pid, (row["space"] as? NSNumber)?.intValue))
    }
    return (windows, nil, query.record)
}

/// A known tree window yabai's list omits, sampled directly by a sweep (`look`, taken at `sampled`): judged now, before
/// its own yabai query (park), which may be slow while the window closes or moves. An exempt one is recorded
/// (exempted, with its final record at the final sweep, which the wrapper's fresh read starts from) and needs no
/// query: nil. Counting on Tim's screen after a placement left it off (windowOnTims false), or
/// at the final sweep, is a problem now (true: the park that follows reports no more of it; false: it does not). An
/// existing unresolved entry takes every sample; a window yabai never placed found counting on his screen becomes
/// unresolved here (unplacedAt) if it was not, so its closing during the query cannot clear it. A placed window's
/// measured Tim state is kept (windowOnTims). Review 3: an exempt sample ends the stretch the window counted in now, at
/// `sampled` (exempted), not at the reply of the query that follows.
@Sendable func omittedSample(_ id: Int, _ look: WindowLook, at sampled: Double, seen: Double, via: String, final: Bool) -> Bool? {
    if let open = unresolved.value[id] {
        unplacedAt(id, look, seen: open.seen, via: open.via, why: open.why, reported: open.reported)
    }
    if let reason = look.exempt {
        exempted(id, look, at: sampled, reason: reason, via: via, found: nil, why: "yabai's window list omits it; not queried before this sample", final: final)
        return nil
    }
    let onTims = look.onTims
    let was = windowOnTims.update { (samples: inout [Int: Bool]) -> Bool? in
        defer { if samples[id] != nil { samples[id] = onTims } }
        return samples[id]
    }
    let back = onTims && was == false
    if back || (onTims && final) {
        if final && endReported.value.contains(id) { return true }  // the end's last read reported it (review 4)
        let pid = look.server?.window?.pid.map { "pid \($0)" } ?? "pid unknown"
        problem(back ? "window \(id) of the tree (\(pid)) was on \(look.timLocation) (found by \(via); yabai's window list omits it) after the guard had seen it on Space \(windowSpaces.value[id].map { String($0) } ?? "?"): macOS showed it to him again"
                     : "window \(id) of the tree (\(pid)) was on \(look.timLocation) at the guard's end (yabai's window list omits it)")
        return true
    }
    if onTims && was == nil && unresolved.value[id] == nil {
        unplacedAt(id, look, seen: seen, via: via, why: "yabai's window list omits it", reported: false)
    }
    return false
}

/// The WindowServer list could not be read by any sweep so far: that is a problem once per run.
let nativeListFailed = Locked(false)

typealias OmittedPark = (id: Int, seen: Double, via: String, latched: Bool)
/// The known tree windows a non-final sweep sampled counting that yabai's list omits, waiting for their park.
let omittedParks = Locked([OmittedPark]())

/// Queues omitted parks on their own serial lane: a slow native query never holds up AX/shown parks on yabaiQueue.
/// A window already waiting is not queued twice (its latched exposure report is kept).
func queueOmittedParks(_ parks: [OmittedPark]) {
    let begin = omittedParks.update { (waiting: inout [OmittedPark]) -> Bool in
        let idle = waiting.isEmpty
        for park in parks {
            if let at = waiting.firstIndex(where: { $0.id == park.id }) {
                waiting[at].latched = waiting[at].latched || park.latched
            } else {
                waiting.append(park)
            }
        }
        return idle && !waiting.isEmpty
    }
    if begin { nativeParkQueue.async { parkNextOmitted() } }
}

func parkNextOmitted() {
    guard let next = omittedParks.update({ (waiting: inout [OmittedPark]) -> OmittedPark? in
        waiting.isEmpty ? nil : waiting.removeFirst()
    }) else { return }
    park(next.id, seen: next.seen, via: next.via, latched: next.latched, native: true)
    if !omittedParks.value.isEmpty { nativeParkQueue.async { parkNextOmitted() } }
}

/// Samples and parks the union of listed and known tree windows, including on-target rows: a sticky window's Tim
/// membership need not match yabai's index. Known windows yabai's list omits (Accessibility's, the windows on screen's,
/// and every owned window of WindowServer's all-window list, which sees ones on hidden Spaces) are sampled directly
/// first, before any window is asked about (omittedSample), unless WindowServer proves them gone or owned outside the
/// tree: an exempt one is recorded and never asked about; one that counts is parked after the listed windows, and
/// accumulates unplaced evidence after the 3 s retries too. A non-final sweep parks those on nativeParkQueue
/// (queueOmittedParks), never the AX/shown lane; the final sweep parks them itself. A failed list is window-list-failed
/// and does not suppress the known-window checks; its exhausted timeout is a problem (queryReply), except the final
/// sweep's, which it owns. A WindowServer list that cannot be read is a problem, once per run.
/// The final sweep's two tries share one absolute deadline, own their timeouts and record final-window-list.
func sweep(_ via: String, final: Bool = false) {
    tracked("sweep (\(via))", final: final) {
        let seen = uptime()
        let read = windowList(ownsTimeout: final, until: seen + queryLimit)
        if final {
            var record = read.record
            record["event"] = "final-window-list"
            record["ok"] = read.windows != nil
            finalWindowList.update { $0 = record }
            emit(record)
        }
        let windows = read.windows ?? []
        if let why = read.why {
            windowListFailed(via: via, why: why)
        } else {
            windowListFailure.update { $0 = nil }
        }
        var member: [pid_t: Bool] = [:]
        func inTree(_ pid: pid_t) -> Bool {
            if let known = member[pid] { return known }
            let owned = tree.contains(pid)
            member[pid] = owned
            return owned
        }
        let listed = Set(windows.map { $0.id })
        // A list that answered may still be stale or incomplete, and one that did not names nothing: every window of the
        // tree that WindowServer has, on hidden Spaces too, joins the known set.
        var native: [Int: (look: WindowLook, at: Double)] = [:]
        if let all = serverWindows(onScreenOnly: false) {
            for w in all where !listed.contains(w.id) {
                guard let pid = w.pid, inTree(pid) else { continue }
                let look = WindowLook(w.id, server: w)
                let sampled = uptime()
                native[w.id] = (look, sampled)
                locateNative(w, pid: pid, via: via)
                sighted(w.id, at: sampled, via: "CGWindowList", look: look)
            }
        } else if nativeListFailed.update({ (failed: inout Bool) -> Bool in defer { failed = true }; return !failed }) {
            problem("the guard's all-window list could not be read (\(via)): a tree window yabai's list omits could go unseen")
        }
        // Every AX, listed and newly shown window is sighted before its first park: this is the complete known set. Each
        // one yabai's list omits is judged by its own sample before any window is asked about.
        var omitted: [OmittedPark] = []
        for id in firstSightings.value.keys.sorted() where !listed.contains(id) {
            let look = native[id]?.look ?? WindowLook(id)
            let sampled = native[id]?.at ?? uptime()
            if look.gone {
                windowsUnknown.update { $0[id] = nil }
            } else if let pid = look.server?.window?.pid, !inTree(pid) {
                windowsUnknown.update { $0[id] = nil }
                unresolved.update { $0[id] = nil }
                countingSince.update { $0[id] = nil }
            } else if let latched = omittedSample(id, look, at: sampled, seen: seen, via: via, final: final) {
                omitted.append((id: id, seen: unresolved.value[id]?.seen ?? seen, via: via, latched: latched))
            }
        }
        for w in windows {
            guard inTree(w.pid) else {
                windowsUnknown.update { $0[w.id] = nil }
                unresolved.update { $0[w.id] = nil }
                countingSince.update { $0[w.id] = nil }
                continue
            }
            sighted(w.id, at: seen, via: via)
            park(w.id, seen: seen, via: via, final: final)
        }
        if final {
            for window in omitted { park(window.id, seen: window.seen, via: window.via, final: true, latched: window.latched) }
        } else {
            queueOmittedParks(omitted)
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
    let name = notification as String
    let via = name == kAXWindowCreatedNotification ? "ax-created" : name == kAXMainWindowChangedNotification ? "ax-main" : "ax-focused"
    sighted(Int(id), at: seen, via: via)
    yabaiQueue.async { park(Int(id), seen: seen, via: via) }
}

/// Subscribes to a tree process's window events: a window created, focused, or made main (GR2: a native tab selected
/// makes its window main, and may show it again on the active Space). A just-launched app answers Accessibility only
/// once its run loop is up, so a refused subscription is retried, every 20 ms for the first 5 s (an adopted client may
/// take that long to become an app), then every 250 ms, until the guard ends.
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
        AXObserverAddNotification(observer, app, kAXMainWindowChangedNotification as CFString, nil)
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
                guard axWindowID(window, &id) == .success, id != 0 else { continue }
                sighted(Int(id), at: seen, via: "ax-existing")
                yabaiQueue.async { park(Int(id), seen: seen, via: "ax-existing") }
            }
        }
    }
}

// MARK: - Windows on screen (GR2; shownQueue)

/// The windows on screen now (WindowServer's list, every display's current Space); nil: unreadable (serverWindows).
@Sendable func shownWindows() -> [ServerWindow]? { serverWindows(onScreenOnly: true) }

/// --rig only: while the file `<name>-hold` exists in the directory of --onscreen's file, waits there (creating
/// `<name>-held` first), for at most 3 s, so a test can change what the guard reads between two of its reads. Outside
/// the rig, or without that file: returns at once.
@Sendable func rigHold(_ name: String) {
    guard rigTest, let onscreenPath else { return }
    let dir = (onscreenPath as NSString).deletingLastPathComponent
    let hold = dir + "/" + name + "-hold"
    guard FileManager.default.fileExists(atPath: hold) else { return }
    FileManager.default.createFile(atPath: dir + "/" + name + "-held", contents: nil)
    let until = uptime() + 3
    while FileManager.default.fileExists(atPath: hold) && uptime() < until { usleep(10_000) }
}

/// GR2 (addendum 2): the tree's windows are re-checked whenever one comes on screen: macOS can show an existing window
/// again (a native tab selected again) on the Space Tim is viewing, with no create event and no Space change (bench's
/// copy 542d177d: ~20 s on his Space, and the check said ok). Every `interval` the windows on screen are read; a tree
/// window not on screen at the read before is sighted and parked individually (even without AX or a yabai row), and
/// starts a sweep (window-shown) of all known windows. A window on screen whose owner was outside the tree when read is
/// read again at the first poll after the tree gains a root or an adoption (Tree.generation): an owner adopted after
/// its window came on screen has that window handled as newly shown. A failed read is a problem: windows shown then
/// could go unseen.
/// GR2 (bench's ruling): every `interval` each exempt tree window (exemptNow) is sampled again too: one gone is
/// dropped, never a problem; one that counts now is parked (window-counted), judged from this sample on.
/// From the launch until the guard's end; shownQueue. Review 3: the end makes one more pass of its own (finalPass)
/// after its last adoption.
final class ShownWindows {
    static let interval = 0.1
    private var last = Set<Int>()
    /// The windows in `last` whose owner was outside the tree, and the tree generation they were read at.
    private var outside = Set<Int>()
    private var outsideGeneration = -1
    private var failed = false
    private var timer: DispatchSourceTimer?  // main

    func start() {  // main
        let ticker = DispatchSource.makeTimerSource(queue: shownQueue)
        ticker.schedule(deadline: .now(), repeating: ShownWindows.interval, leeway: .milliseconds(20))
        ticker.setEventHandler { [unowned self] in self.pollNow() }
        ticker.resume()
        timer = ticker
    }

    func stop() { timer?.cancel() }  // main

    /// One poll, unless the guard is ending (the timer's; the rig's `poll`). shownQueue.
    func pollNow() { if !stopping { poll() } }

    /// GR2 (review 3): at the guard's end, after its last adoption (the end's own scan) and before the final sweep,
    /// every window on screen whose owner is in the tree now is sighted, so the final sweep judges it: an owner adopted
    /// after the last poll (or by that scan) has windows no poll will read again. A read that fails is a problem.
    /// Review 4: each such window's sample is judged here, before the final sweep's window list (which may wait while
    /// the window closes, and then finds it gone): one on Tim's screen, not exempt, is a problem now (endReported, so
    /// the final sweep reports no more of it). Review 6: each window has ONE sample here, which registers its sighting
    /// (when this read is its first) and is judged: an on-Tim sample is never lost to a later one that finds the window
    /// gone. When that sample shows the window gone (closed since the read of the windows on screen): one sighted before
    /// is judged by its earlier samples, where they were taken (review 5; the final sweep finds it gone too); one first
    /// sighted here was never read anywhere but on screen, so it counts as on Tim's screen (fail closed, as at the end's
    /// report of a window gone unplaced), a problem. The rig can hold the pass after that read (rigHold "final-pass")
    /// and after each window's sighting (rigHold "final-sample"). shownQueue, waited for by the end.
    func finalPass() {
        guard let rows = shownWindows() else {
            problem("the windows on screen could not be read at the guard's end: a tree window on Tim's screen whose owner joined the tree late could go unseen")
            return
        }
        rigHold("final-pass")
        let seen = uptime()
        var member: [pid_t: Bool] = [:]
        for row in rows {
            guard let pid = row.pid else { continue }
            if member[pid] == nil { member[pid] = tree.contains(pid) }
            guard member[pid] == true else { continue }
            let look = WindowLook(row.id)  // the sighting's sample and the verdict's (review 6)
            let first = sighted(row.id, at: seen, via: "final-shown", look: look)
            rigHold("final-sample")
            if look.gone {  // closed since the read of the windows on screen (review 5)
                if first && endReported.update({ $0.insert(row.id).inserted }) {
                    problem("window \(row.id) of the tree (pid \(pid)) was on screen at the end's last read of the windows on screen and gone by its first sample: nothing showed it off Tim's screen, so it counts as on it")
                }
                continue
            }
            if look.exempt == nil && look.onTims && endReported.update({ $0.insert(row.id).inserted }) {
                problem("window \(row.id) of the tree (pid \(pid)) was on \(look.timLocation) at the guard's end (found by the end's last read of the windows on screen)")
            }
        }
    }

    private func poll() {
        resample()
        guard let rows = shownWindows() else {
            if !failed {
                failed = true
                problem(String(format: "the windows on screen could not be read %.3f s after launch: a tree window shown again on Tim's Space could go unseen until a Space change", uptime() - t0))
            }
            return
        }
        let generation = tree.generation
        let regrown = generation != outsideGeneration
        var member: [pid_t: Bool] = [:]
        var shown = false
        var stillOutside = Set<Int>()
        for row in rows {
            guard let pid = row.pid else { continue }
            if last.contains(row.id) && !(regrown && outside.contains(row.id)) {
                if outside.contains(row.id) { stillOutside.insert(row.id) }
                continue
            }
            if member[pid] == nil { member[pid] = tree.contains(pid) }
            if member[pid] == true {
                shown = true
                let seen = uptime()
                sighted(row.id, at: seen, via: "window-shown")
                yabaiQueue.async { park(row.id, seen: seen, via: "window-shown") }
            } else {
                stillOutside.insert(row.id)
            }
        }
        last = Set(rows.map { $0.id })
        outside = stillOutside
        outsideGeneration = generation
        if shown { yabaiQueue.async { sweep("window-shown") } }
    }

    private func resample() {
        for id in exemptNow.value.keys.sorted() {
            let sampled = uptime()
            let look = WindowLook(id)
            if look.gone {
                exemptNow.update { $0[id] = nil }
            } else if look.exempt == nil {
                exemptNow.update { $0[id] = nil }
                countingSince.update { $0[id] = (at: sampled, onTims: look.onTims) }
                yabaiQueue.async { park(id, seen: sampled, via: "window-counted") }
            }
        }
    }
}
let shownWatch = ShownWindows()

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

/// Activates Tim's app `pid`. The rig activates nothing: it records the call (rig-activate) and takes `pid` for
/// frontmost, as macOS would once the activation lands. main.
@Sendable func activate(_ pid: pid_t) -> Bool {  // main
    if rigTest {
        rigFront = pid
        emit(["event": "rig-activate", "pid": Int(pid)])
        return true
    }
    guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
    if #available(macOS 14, *) { return app.activate() }
    return app.activate(options: [.activateIgnoringOtherApps])
}

/// The frontmost app: its pid and its record (the rig: the app its stand-ins last made frontmost). main.
@Sendable func frontmost() -> (pid: pid_t?, app: Any) {
    if rigTest { return (rigFront, rigFront.map { rigApp($0) } ?? NSNull()) }
    let app = workspace.frontmostApplication
    return (app?.processIdentifier, describe(app))
}

/// GR2 item 6: the system modals nothing is ever fronted over (WindowServer owner names): SecurityAgent (keychain and
/// administrator prompts; roblox's run 1, 20:57:16Z, where re-activating Finder took front from its prompt) and,
/// [INFERENCE] by name only, the authentication and consent prompts of coreautha, UserNotificationCenter and
/// universalAccessAuthWarn.
let systemModalOwners: Set<String> = ["SecurityAgent", "coreautha", "UserNotificationCenter", "universalAccessAuthWarn"]

/// What the windows on screen showed of system modals (review 3: an unreadable read is not "none").
enum ModalSample {
    case absent
    case modal(pid_t, String)
    case unreadable
}

/// Why nothing is fronted while the windows on screen cannot be read (GR2 item 6, review 3).
let modalUnknown = "the windows on screen could not be read, so a system modal could not be ruled out"

/// A system modal on screen now (WindowServer's windows on screen; the rig's stand-in): its owner's pid and name;
/// absent, from a read that names none; unreadable, when the windows on screen cannot be read, which never counts as
/// none: nothing is fronted then. Any thread; no child process.
@Sendable func systemModal() -> ModalSample {
    guard let rows = shownWindows() else { return .unreadable }
    for w in rows {
        if let pid = w.pid, let name = w.owner, systemModalOwners.contains(name) { return .modal(pid, name) }
    }
    return .absent
}

/// A modal sample for a record: {pid, name}, null (none), or "unreadable".
@Sendable func modalRecord(_ sample: ModalSample) -> Any {
    switch sample {
    case .absent: return NSNull()
    case .modal(let pid, let name): return ["pid": Int(pid), "name": name] as [String: Any]
    case .unreadable: return "unreadable"
    }
}

/// yabai's focused display, by index; nil: the query failed or named none. Off main.
@Sendable func focusedDisplay() -> Int? {
    ((yabai(["query", "--displays", "--display"]) as? [String: Any])?["index"] as? NSNumber)?.intValue
}

/// An app record (describe, rigApp) for a problem's text.
@Sendable func appText(_ app: Any?) -> String {
    guard let app = app as? [String: Any] else { return "no app" }
    return "\(app["name"].map { "\($0)" } ?? "?") (pid \(app["pid"].map { "\($0)" } ?? "?"))"
}

/// GR2 item 6 (live, roblox's runs 1 and 3): re-activating an app that has no window on Tim's display (Finder with
/// none) leaves yabai's focused display, and the key window's screen, where a tree activation took them (CanvasTest),
/// so his keystrokes could land there. Review 3: the guard focuses no display. `yabai -m display --focus` is not
/// display-only: yabai focuses and raises the first window on that display's Space (on an empty display it can post
/// mouse clicks), which could front another app over a system modal, or a tree window not yet parked, without any of
/// the restore target's checks. So when no window of Tim's was focused for the restore, this checks instead: a system
/// modal on screen is re-fronted, whichever display has focus (unless it is frontmost already); then yabai's focused
/// display is read, and one that is not his (the display holding Space 1, from the baseline) is a problem, "display
/// restore unsupported", naming the focus before (at launch) and now: nothing is focused for it. A modal sample that
/// cannot be read is a problem, and nothing is fronted. Each step is still Tim's to want: `wanted` (main; nil: still
/// wanted, else why not: he chose an app since) is asked as the check begins, after each read that can block, and in
/// the main-queue turn that activates the modal; once it is not, the check stops (`reason`), no problem. Returns the
/// record (restore-call's `display`; display-check). restoreQueue.
@Sendable func checkTimsDisplay(after what: String, wanted: @escaping () -> String?) -> [String: Any] {
    var record: [String: Any] = ["display": timDisplay ?? NSNull(), "focused": NSNull(), "modal": NSNull(), "ok": NSNull(),
                                 "reason": NSNull()]
    func stopped() -> Bool {
        guard let why = DispatchQueue.main.sync(execute: wanted) else { return false }
        record["reason"] = why
        return true
    }
    if stopped() { return record }
    switch systemModal() {
    case .unreadable:
        record["modal"] = "unreadable"
        problem("after \(what), \(modalUnknown) or re-fronted")
    case .modal(let pid, let name):
        let turn = DispatchQueue.main.sync { () -> (why: String?, front: Bool, ok: Bool) in
            if let why = wanted() { return (why, false, false) }
            // Review 4: the guard's own re-front, registered in this turn as finalActivation's is: its activation gives
            // focus back (reverted, method modal) and is never taken for Tim's takeover, which would stop this check.
            policy.fronted(modal: pid)
            if frontmost().pid == pid { return (nil, true, false) }
            lastRestore.update { $0 = ("modal", nil) }
            return (nil, false, activate(pid))
        }
        if let why = turn.why {
            record["reason"] = why
            return record
        }
        record["modal"] = ["pid": Int(pid), "name": name, "frontmost": turn.front, "refronted": turn.ok] as [String: Any]
    case .absent:
        break
    }
    let focused = focusedDisplay()
    if stopped() { return record }
    record["focused"] = focused ?? NSNull()
    let ok = timDisplay != nil && focused == timDisplay
    record["ok"] = ok
    if !ok {
        let (before, front) = DispatchQueue.main.sync { () -> (String, String) in
            let window = (focusAtLaunch["window"] as? NSNumber).map { "window \($0.intValue)" } ?? "no focused window"
            let display = (focusAtLaunch["focusedDisplay"] as? NSNumber).map { "display \($0.intValue)" } ?? "display unknown"
            return ("\(appText(focusAtLaunch["app"])), \(window), \(display)", appText(frontmost().app))
        }
        let now = focused.map { "display \($0)" } ?? "unreadable"
        problem("display restore unsupported: after \(what), yabai's focused display is \(now), not Tim's (\(timDisplay.map { "display \($0)" } ?? "unknown")), and the guard focuses no display (yabai -m display --focus raises a window of its own choosing); focus before: \(before); after: \(front), \(now)")
    }
    return record
}

/// Before a revert to `pid`, and again before its fallback activation: why it is no longer wanted (focus goes back
/// to another app or none, or is already back, as main's policy says; or the app joined the tree or is another
/// process now). nil: still wanted. restoreQueue.
@Sendable func unwanted(_ pid: pid_t) -> String? {
    if let why = DispatchQueue.main.sync(execute: { policy.unwanted(pid) }) { return why }
    return revalidateTarget(pid) ? nil : "pid \(pid) joined the tree or is another process now"
}

/// Whether window `id` may be focused for the restore target, by an owner query made for this focus (its owner must
/// be the target's pid with its start time, outside the tree). The answer counts only if no activation, Space
/// change, app launch or exit, and no change of the restore target came while the query ran: a stale answer is
/// discarded and the query made again, until `deadline` (uptime), but only while `pending` (asked before each
/// query) finds the focus still wanted. Returns what the check found and, if a query ran out of time, the time it
/// had. A window that turns out to be another process's is dropped from the target. `ownsTimeout`: the caller
/// records a query that runs out of time (the revert does), not Helpers. Off main.
@Sendable func confirmWindow(_ id: Int, until deadline: Double, pending: () -> String?,
                             ownsTimeout: Bool = false) -> (vouch: Vouch, timedOut: Double?) {
    var timedOut: Double?
    let callerBudget = max(0, deadline - uptime())
    let found = vouch(id, pending: pending) {
        let left = deadline - uptime()
        guard left > 0.01 else { return nil }
        let began = (epoch: timEpoch.value, target: restoreTarget.value)
        let fact: WindowFact
        let query = queryReply(["query", "--windows", "--window", String(id)], timeout: left, ownsTimeout: ownsTimeout, replyUntil: deadline)
        switch query.reply {
        case .exited(0, _):
            if let w = query.value as? [String: Any], let owner = (w["pid"] as? NSNumber)?.int32Value {
                fact = .owner(owner, start: processStart(owner), inTree: tree.adopt(owner, via: "restore-check"),
                              space: (w["space"] as? NSNumber)?.intValue)
            } else {
                fact = .unknown("yabai's answer about window \(id) is unreadable")
            }
        case .exited: fact = .unknown(unknownWindow(id))
        case .timedOut:
            timedOut = callerBudget
            fact = .unknown(unanswered(id))
        case .refused(let why): fact = .unknown(why)
        }
        return restoreTarget.update { (target: inout RestoreTarget) -> OwnerReply in
            guard timEpoch.value == began.epoch && target == began.target else { return .stale }
            return .judged(target.confirm(id, fact))
        }
    }
    return (found, timedOut)
}

/// An activation of Tim's app `pid` in one main-queue turn with its checks: focus still goes back to `pid` with the
/// theft still open (main's policy), `pid` is still the process it was taken from and outside the tree, and then the
/// activation, with no activation or adoption served in between. `method` is how a revert it lands records it:
/// "immediate", made in the turn that decided the theft, or "activate", the revert's fallback. GR2 item 6: with a
/// system modal on screen, Tim's app is never fronted over it: the modal's process is re-fronted instead (method
/// "modal"), and its activation gives focus back. Review 3: windows on screen that cannot be read cannot rule a modal
/// out, so nothing is fronted then (refused; a problem). main.
@Sendable func finalActivation(_ pid: pid_t, method: String = "activate") -> FinalTurn {
    if let why = policy.unwanted(pid) { return .unwanted(why) }
    guard revalidateTarget(pid) else { return .unwanted("pid \(pid) joined the tree or is another process now") }
    switch systemModal() {
    case .modal(let modal, let name):
        lastRestore.update { $0 = ("modal", nil) }
        policy.fronted(modal: modal)
        return .modal(modal, name, activate(modal))
    case .unreadable:
        let why = "\(modalUnknown): \(method == "immediate" ? "the activation at once" : "the revert's fallback activation") of pid \(pid) was not made"
        problem(why)
        return .refused(why)
    case .absent:
        lastRestore.update { $0 = (method, nil) }
        return .activated(activate(pid))
    }
}

/// Why no window is focused for Tim now (GR2 item 6): a system modal on screen, or one that cannot be ruled out
/// (review 3). nil: a read named none. Any thread.
@Sendable func modalBlocksFocus() -> String? {
    switch systemModal() {
    case .modal(let pid, let name): return "a system modal (\(name), pid \(pid)) is on screen: no window is focused over it"
    case .unreadable: return "\(modalUnknown): no window is focused"
    case .absent: return nil
    }
}

/// Gives focus back to Tim's app `pid`, which a tree process took at `stolenAt` (uptime), after the activation made
/// at once in the turn that decided the theft (`immediate`: the app it fronted, his or a system modal in its place;
/// nil: it did not run or failed): unless focus is back by then, performRevert with the live checks, the focus by
/// window id once its owner is vouched for, and the fallback activation (cooperative on macOS 14+: a slow app answers
/// late) in one main-queue turn with its checks. An owner query that ran out of time is settled after it. GR2 item 6:
/// no window is focused over a system modal, nor while one cannot be ruled out; and unless a window of his was
/// focused, Tim's display is checked (checkTimsDisplay; restore-call's `display`) while Tim has chosen no app since the
/// theft (`choice`, RestorePolicy.choice then) and focus still goes back to `pid`. restoreQueue, scheduled by main, so
/// the guard's end waits for it.
@Sendable func revert(to pid: pid_t, stolenAt: Double, immediate: pid_t?, choice: Int) {
    let began = uptime()
    var ownerTimeout: (query: [String], allowed: Double)?
    let outcome = performRevert(
        window: restoreTarget.value.window(for: pid),
        unwanted: { unwanted(pid) },
        confirm: { id in
            let check = confirmWindow(id, until: uptime() + focusTimeout, pending: { unwanted(pid) }, ownsTimeout: true)
            if let allowed = check.timedOut { ownerTimeout = (["query", "--windows", "--window", String(id)], allowed) }
            return check.vouch
        },
        focus: { id in
            if let why = modalBlocksFocus() { return why }
            let prior = lastRestore.value
            lastRestore.update { $0 = ("window", id) }
            let reply = yabaiReply(["window", "--focus", String(id)], timeout: focusTimeout)
            if case .exited(0, _) = reply { return nil }
            lastRestore.update { $0 = prior }
            switch reply {
            case .exited(let code, _): return "exit \(code)"
            case .timedOut: return "no answer within \(focusTimeout) s"
            case .refused(let why): return why
            }
        },
        activate: { DispatchQueue.main.sync { finalActivation(pid) } })
    var display: Any = NSNull()
    if outcome.method != "window" {
        display = checkTimsDisplay(after: "the revert to pid \(pid)") {
            if policy.choice != choice { return "Tim chose an app since the theft: focus stays where he put it" }
            return policy.userFront == pid ? nil : "focus no longer goes back to pid \(pid)"
        }
    }
    let done = uptime()
    emit(["event": "restore-call", "to": Int(pid), "immediate": immediate != nil, "method": outcome.method, "window": outcome.window ?? NSNull(),
          "ok": outcome.ok, "windowError": outcome.windowError ?? NSNull(), "reason": outcome.reason ?? NSNull(),
          "display": display, "callMs": ms(done - began), "sinceTheftMs": ms(done - stolenAt)])
    if let ownerTimeout {
        settleOwnerTimeout(ownerTimeout.query, allowed: ownerTimeout.allowed, outcome: outcome, immediate: immediate, to: pid,
                           fallbackMs: ms(done - stolenAt))
    }
}

/// The owner query before a revert's focus ran out of time: an owner-query-timeout event with the query, its
/// timeout, the revert's latency (from the theft to its return; fallbackMs), whether the activation made at once
/// ran, and the read after the revert; expected-slow only as ownerTimeoutProblem rules, otherwise a problem too. The
/// read: the frontmost app (NSWorkspace's) and SkyLight's Space for Tim's display, every 25 ms for up to 1 s after
/// the revert (an activation lands asynchronously), until both are what is expected; taken when an activation (at
/// once, `immediate`, the app it fronted; or the fallback) ran and succeeded. The app expected frontmost is the one that
/// activation fronted: Tim's, or the system modal re-fronted in its place (GR2 item 6, review 3). restoreQueue.
@Sendable func settleOwnerTimeout(_ query: [String], allowed: Double, outcome: RevertOutcome, immediate: pid_t?, to pid: pid_t,
                                  fallbackMs: NSDecimalNumber) {
    let fellBack = uptime()
    var read: PostFallbackRead?
    var shown: [String: Any] = [:]
    let activated = (outcome.method == "activate" || outcome.method == "modal") && outcome.ok
    let front = activated ? outcome.fronted ?? pid : immediate ?? pid
    if immediate != nil || activated {
        while true {
            let (now, app) = DispatchQueue.main.sync { frontmost() }
            let space = spaceWatch.sample(via: "fallback-check")
            read = PostFallbackRead(front: now, space: space?.index, error: space == nil ? "SkyLight's record shows no display holding Space 1" : nil)
            shown = ["front": app, "space": space?.index ?? NSNull(), "spaceId": space.map { NSNumber(value: $0.id) } ?? NSNull(),
                     "afterMs": ms(uptime() - fellBack), "error": read?.error ?? NSNull()]
            if read?.front == front, let index = space?.index, index == spacePolicy.value.expected { break }
            if uptime() - fellBack >= 1 { break }
            usleep(25_000)
        }
    }
    let expected = spacePolicy.value.expected
    let why = ownerTimeoutProblem(outcome, immediate: immediate, to: pid, expectedSpace: expected, read: read)
    let record: [String: Any] = [
        "event": "owner-query-timeout", "query": query, "timeoutS": decimal(allowed, 1), "to": Int(pid),
        "window": outcome.window ?? NSNull(), "method": outcome.method, "immediate": immediate != nil, "fallbackMs": fallbackMs,
        "expected": ["pid": Int(front), "space": expected.map(spaceField) ?? NSNull()] as [String: Any],
        "read": read == nil ? NSNull() as Any : shown as Any, "expectedSlow": why == nil, "problem": why ?? NSNull(),
    ]
    ownerTimeouts.update { $0.append(record) }
    emit(record)
    // Bench's ruling, decided here: a timeout that the read after the revert did not clear is a problem.
    if let why { problem("yabai -m \(query.joined(separator: " ")) did not answer within \(String(format: "%.1f", allowed)) s: \(why)") }
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

/// The tree moved Tim's display to `from`: focusing his restore-target window (its app and its owner checked
/// again first) brings `to`, the expected Space, back. The restore must still be wanted (a fresh read still finds
/// his display where the tree took it, wanting this window) before each owner query and again immediately before
/// the focus; once it is not, nothing is focused (`reason`). Recorded either way: `ok` only when a direct read
/// shows his display on `to` again (every 20 ms, for up to 1 s). timQueue.
@Sendable func restoreSpace(from: Int, to: Int, window: Int, theftAt: Double?) {
    var focused = false
    var windowError: String?
    var reason: String?
    if let pid = restoreTarget.value.pid, revalidateTarget(pid), restoreTarget.value.window == window {
        let pending = { spaceWatch.restorePending(window) }
        switch confirmWindow(window, until: uptime() + focusTimeout, pending: pending).vouch {
        case .unwanted(let why):
            reason = why
        case .refused(let why):
            windowError = why
        case .vouched:
            if let why = pending() {
                reason = why
            } else if let why = modalBlocksFocus() {  // GR2 item 6: nothing is fronted over a system modal
                windowError = why
            } else if case .exited(0, _) = yabaiReply(["window", "--focus", String(window)], timeout: focusTimeout) {
                focused = true
            } else {
                windowError = "the focus failed"
            }
        }
    } else {
        windowError = "the restore target's app joined the tree or exited"
    }
    var after = spaceWatch.sample(via: "restore")
    let until = uptime() + 1
    while focused && after?.index != to && uptime() < until {
        usleep(20_000)
        after = spaceWatch.sample(via: "restore")
    }
    var record: [String: Any] = ["event": "space-restored", "from": spaceField(from), "to": after?.index ?? NSNull(), "expected": to,
                                 "window": window, "focused": focused, "windowError": windowError ?? NSNull(),
                                 "reason": reason ?? NSNull(), "ok": after?.index == to]
    if from < 0 { record["fromId"] = -from }
    record["latencyMs"] = theftAt.map { ms(uptime() - t0 - $0) } ?? NSNull()
    spaceEvents.update { $0.append(record) }
    emit(record)
}

// MARK: - Tim's display, read directly (SkyLight)

/// SkyLight's record of the Spaces each display shows (SLSCopyManagedDisplaySpaces), which yabai reads too: a read
/// with no yabai event loop in between. Looked up on first use, which comes after the GUI-session check; a SkyLight
/// without it gives no read, and then nothing launches.
enum SkyLight {
    static let displaySpaces: (() -> Any?)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let connect = dlsym(handle, "SLSMainConnectionID"), let copy = dlsym(handle, "SLSCopyManagedDisplaySpaces") else { return nil }
        let connection = unsafeBitCast(connect, to: (@convention(c) () -> Int32).self)()
        let copySpaces = unsafeBitCast(copy, to: (@convention(c) (Int32) -> UnsafeRawPointer?).self)
        return {
            guard let spaces = copySpaces(connection) else { return nil }
            return Unmanaged<CFArray>.fromOpaque(spaces).takeRetainedValue() as NSArray
        }
    }()

    /// GR2: where SkyLight puts window `id`, read directly (no yabai): SLSCopySpacesForWindows (selector 0x7, every
    /// Space it is on; none: ordered out, or gone) and SLSCopyManagedDisplayForWindow (its display's identifier), the
    /// calls yabai makes for the same [INFERENCE: signatures as in yabai's headers; not exercised here, where no GUI
    /// may be touched]. nil: unreadable. The rig reads its stand-in (--skylight-windows: {"<id>": {"spaces": [id],
    /// "display": d}}; "spaces": [] is ordered out; a window not in it, or no file, is unreadable).
    static func windowPlace(_ id: Int) -> WindowPlace? {
        if rigTest {
            guard let skylightWindowsPath, let data = try? Data(contentsOf: URL(fileURLWithPath: skylightWindowsPath)),
                  let all = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let row = all[String(id)] as? [String: Any],
                  let spaces = row["spaces"] as? [NSNumber] else { return nil }
            return WindowPlace(spaces: spaces.map { $0.uint64Value }, display: row["display"] as? String)
        }
        return livePlace?(id)
    }

    private static let livePlace: ((Int) -> WindowPlace?)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let connect = dlsym(handle, "SLSMainConnectionID"), let copy = dlsym(handle, "SLSCopySpacesForWindows") else { return nil }
        let connection = unsafeBitCast(connect, to: (@convention(c) () -> Int32).self)()
        let spacesFor = unsafeBitCast(copy, to: (@convention(c) (Int32, Int32, CFArray) -> UnsafeRawPointer?).self)
        let displayFor = dlsym(handle, "SLSCopyManagedDisplayForWindow").map {
            unsafeBitCast($0, to: (@convention(c) (Int32, UInt32) -> UnsafeRawPointer?).self)
        }
        return { id in
            let wid = UInt32(truncatingIfNeeded: id)
            guard let raw = spacesFor(connection, 0x7, [NSNumber(value: wid)] as CFArray),
                  let list = (Unmanaged<CFArray>.fromOpaque(raw).takeRetainedValue() as NSArray) as? [NSNumber] else { return nil }
            let spaces = list.map { $0.uint64Value }
            let display = displayFor?(connection, wid).map { Unmanaged<CFString>.fromOpaque($0).takeRetainedValue() as String }
            return WindowPlace(spaces: spaces, display: display)
        }
    }()
}

/// Tim's display, read directly: at every Space notification, at each activation, every SpaceSampling.interval
/// through each theft and grace window (macOS can report two changes in one notification), around each Space
/// restore, after a fallback activation, and once more as the guard seals its records. Each read takes every
/// display. The reads go to SpacePolicy one at a time, in the order taken, so each Space the tree shows him is a
/// breach (space-breach) the moment it is read; each read that changes what his display shows is in the Space
/// history (display-space; a notification's read is logged even with no change, with what changed since the
/// notification before it and what explains it). A notification that nothing may explain (SpacePolicy.noticed) is
/// a change and back that no read saw: in a theft or grace window a breach that cannot be named (space-unseen). A
/// Space yabai's map does not know is recorded by its id, and the map asked for again (at most once a second). A
/// read that fails, and, while a theft or grace window lasts, reads more than SpaceSampling.maxGap apart, are
/// problems: nothing then proves that no Space went unseen. A restore is asked of timQueue for each new breach and
/// each notification that still finds the tree's Space; it acts on the latest read. Every read holds the lock
/// throughout. A change of any display that a read other than a notification's finds must be followed by a
/// notification within NoticeFeed.limit, or the notifications are not arriving: a problem, once per run. Once the
/// guard's end has done its work, it waits (awaitNotices, at most NoticeFeed.limit) while such a change still waits
/// for its notification; then the poll stops (stopPolling, off main); then main takes the last read and seals the
/// watch (seal) in the turn that takes the summary's records: a change still waiting then is a problem too, no read
/// records anything after that, and a notification that comes after it is a problem, never dropped unrecorded.
final class SpaceWatch {
    private let lock = NSLock()
    private var rows: (() -> Any?)?
    private var map: SpaceMap?
    private var sampling = SpaceSampling()
    private var notices = SpaceNotices(since: 0)
    private var feed = NoticeFeed()
    private var shown: UInt64?
    private var failing = false
    /// The poll stopped for good (the guard's end).
    private var pollStopped = false
    private var sealed = false
    private var timer: DispatchSourceTimer?
    private var nextRefresh = -Double.infinity
    private var refreshing = false
    private var restoreWanted: (from: Int, to: Int, window: Int, theftAt: Double?)?
    private var restoreQueued = false
    /// When a read last asked for a restore (seconds since launch): a poll asks again at most every 0.25 s.
    private var restoreAsked = -Double.infinity
    private var trail: [[String: Any]] = []

    /// The Space history: each read that changed what Tim's display shows.
    var history: [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return trail
    }

    /// The index of the Space Tim's display showed at the last read; nil: none read yet, or a Space yabai's map does
    /// not know.
    var shownIndex: Int? {
        lock.lock(); defer { lock.unlock() }
        return shown.flatMap { map?.indexes[$0] }
    }

    /// The index yabai's map gives SkyLight Space `id`; nil: one it does not know.
    func index(of id: UInt64) -> Int? {
        lock.lock(); defer { lock.unlock() }
        return map?.indexes[id]
    }

    /// A window sample met a SkyLight Space yabai's map does not know: ask yabai for its map again (one request at a
    /// time, at most once a second, as for a display read), so a later sample may know it.
    func mapMissed() {
        lock.lock(); defer { lock.unlock() }
        refreshMap()
    }

    enum NativePlacement { case unknown, onTims, elsewhere, assigned }

    /// Classifies every membership with one map/read snapshot; an unknown cannot hide beside a target.
    /// Unlike ordinary counting, an assigned Space is not exempt from physical Tim visibility. Expected-Space
    /// counting is enforced by the caller's WindowLook.onTims before accepting this proof.
    func placementOnAgent(_ memberships: [UInt64]) -> NativePlacement {
        lock.lock(); defer { lock.unlock() }
        guard !memberships.isEmpty, let map else { return .unknown }
        var assigned = false, tims = false
        for sid in memberships {
            guard let index = map.indexes[sid] else { return .unknown }
            if timMembership(index, shown: sid == shown) { tims = true }
            if index == space { assigned = true }
        }
        return tims ? .onTims : assigned ? .assigned : .elsewhere
    }

    /// GR2: whether SkyLight Space `id` is on Tim's screen: the Space his display showed at the last read, or one whose
    /// index is on his screen (onTimsScreen).
    func showsTim(spaceId id: UInt64) -> Bool {
        lock.lock()
        let (current, index) = (shown, map?.indexes[id])
        lock.unlock()
        if let index { return onTimsScreen(index) }
        return id == current
    }

    /// Starts reading with `rows` (SkyLight's displays, or the rig's stand-in) and yabai's map from the baseline;
    /// returns the first read. main, before anything launches.
    func begin(rows: @escaping () -> Any?, map: SpaceMap) -> (id: UInt64, index: Int?)? {
        lock.lock()
        self.rows = rows
        self.map = map
        notices = SpaceNotices(since: uptime() - t0)
        lock.unlock()
        return sample(via: "baseline")
    }

    /// One read of every display, `via` what prompted it; `input`, the last HID input then (a hint), if known.
    /// Returns the Space Tim's display shows (its SkyLight id, and its index if yabai's map knows it); nil: the
    /// read failed, or the watch is sealed (a notification then is a problem).
    @discardableResult
    func sample(via: String, input: Double? = nil) -> (id: UInt64, index: Int?)? {
        lock.lock(); defer { lock.unlock() }
        let t = uptime() - t0
        let notice = via == "notification"
        guard !sealed else {
            if notice {
                problem(String(format: "a Space notification came %.3f s after launch, after the guard sealed its records: what it reported is not in them", t))
            }
            return nil
        }
        if let late = feed.read(at: t) { missed(late, sealing: false) }
        if let from = sampling.read(at: t) {
            problem(String(format: "Tim's display went unread for %.0f ms in a theft or grace window (%.3f to %.3f s after launch): a Space shown then may be unrecorded",
                           (t - from) * 1000, from, t))
        }
        guard let map, let read = DisplayRead(rows?(), anchor: map.anchor) else {
            if notice {
                _ = notices.notified(at: t, readOK: false)  // nothing explains it; the failed read is a problem
                feed.notified()
            }
            if !failing {
                failing = true
                problem(String(format: "Tim's display could not be read directly %.3f s after launch (%@): SkyLight's record shows no display holding Space 1", t, via))
            }
            refreshMap()
            return nil
        }
        failing = false
        let moved = notices.read(read)
        if notice {
            feed.notified()
        } else {
            var changes = moved.tim ? [NoticeFeed.Change(at: t, display: nil, space: read.timSpace, via: via)] : []
            for key in moved.others {
                if let other = read.others[key] { changes.append(NoticeFeed.Change(at: t, display: key, space: other, via: via)) }
            }
            feed.found(changes)
        }
        let id = read.timSpace
        let index = map.indexes[id]
        if index == nil { refreshMap() }
        let changed = id != shown
        shown = id
        if changed { trail.append(["at": decimal(t, 3), "space": index ?? NSNull(), "spaceId": NSNumber(value: id), "via": via]) }
        var event: [String: Any] = ["event": "display-space", "space": index ?? NSNull(), "spaceId": NSNumber(value: id), "via": via, "changed": changed]
        var noticed: (since: Double, tim: String?, others: [String])?
        if notice {
            let found = notices.notified(at: t, readOK: true)
            let tims = read.tim.isEmpty ? "Tim's display" : read.tim
            noticed = (found.since, found.tim ? tims : nil, found.others)
            event["timChanged"] = found.tim
            event["othersChanged"] = found.others
            event["timsDisplay"] = tims
        } else if !changed {
            event = [:]
        }
        judge(spaceKey(index: index, id: id), id: id, at: t, via: via, input: input, noticed: noticed, event: event)
        return (id, index)
    }

    /// What SpacePolicy decides for the read, recorded after `event` (the read's display-space; empty: none):
    /// `noticed`, for a notification's read, is when the notification before it was read, Tim's display if it was
    /// read to change since then, and the other displays that were. Lock held.
    private func judge(_ key: Int, id: UInt64, at t: Double, via: String, input: Double?,
                       noticed: (since: Double, tim: String?, others: [String])?, event: [String: Any]) {
        let theft = theftState.value
        let target = restoreTarget.value
        let (verdict, decision, revoked, expected, breach, charged) = spacePolicy.update {
            (policy: inout SpacePolicy) -> (SpacePolicy.Notice?, SpacePolicy.Decision, Int?, Int?, Int?, [Double]) in
            let verdict = noticed.map { policy.noticed(at: t, since: $0.since, theft: theft, tim: $0.tim, others: $0.others) }
            let decision = policy.observed(key, since: t, theft: theft, window: target.window, windowSpace: target.windowSpace)
            return (verdict, decision, policy.revoked, policy.expected, policy.breach, policy.unseenCharged)
        }
        func hint() -> Any { input.map { ms(t - $0) } ?? NSNull() }
        func record(_ fields: [String: Any]) {
            spaceEvents.update { $0.append(fields) }
            emit(fields)
        }
        func unseen(_ at: Double, others: [String]) {
            record(["event": "space-unseen", "noticeAt": decimal(at, 3), "expected": expected.map(spaceField) ?? NSNull(),
                    "othersChanged": others, "sinceTheftMs": theft.lastTheft.map { ms(at - $0) } ?? NSNull(),
                    "theftAt": theft.lastTheft.map { decimal($0, 3) } ?? NSNull()])
        }
        if !event.isEmpty {
            var fields = event
            if let verdict {
                switch verdict {
                case .explained(let display): fields["explainedBy"] = display
                case .tree, .tim: fields["explainedBy"] = NSNull()
                }
            }
            emit(fields)
        }
        for at in charged { unseen(at, others: []) }
        if verdict == .tree { unseen(t, others: noticed?.others ?? []) }
        if let revoked {
            record(["event": "user-space-revoked", "space": spaceField(revoked), "expected": expected.map(spaceField) ?? NSNull(),
                    "theftAt": theft.lastTheft.map { decimal($0, 3) } ?? NSNull()])
        }
        if breach != nil {
            record(["event": "space-breach", "from": spaceField(key), "spaceId": NSNumber(value: id), "expected": expected.map(spaceField) ?? NSNull(),
                    "via": via, "sinceTheftMs": theft.lastTheft.map { ms(t - $0) } ?? NSNull(),
                    "theftAt": theft.lastTheft.map { decimal($0, 3) } ?? NSNull()])
        }
        switch decision {
        case .unchanged:
            restoreWanted = nil
        case .user(let space):
            restoreWanted = nil
            emit(["event": "user-space", "space": spaceField(space), "spaceId": NSNumber(value: id), "sinceInputMs": hint()])
        case .restore(let from, let to, let window):
            restoreWanted = (from, to, window, theft.lastTheft)
            let ask = breach != nil || via == "notification" || via == "activation" || (via == "poll" && t - restoreAsked >= 0.25)
            if !restoreQueued && ask {
                restoreQueued = true
                restoreAsked = t
                timQueue.async { self.runRestore() }
            }
        case .unrestorable(let from, let to):
            restoreWanted = nil
            if breach != nil {
                record(["event": "space-unrestorable", "from": spaceField(from), "spaceId": NSNumber(value: id), "to": to, "expected": to,
                        "window": target.window ?? NSNull(), "sinceInputMs": hint()])
            }
        }
    }

    /// The restore the latest read wants, if one still is when timQueue gets to it. timQueue.
    private func runRestore() {
        tracked("Space restore") {
            lock.lock()
            let want = restoreWanted
            restoreQueued = false
            lock.unlock()
            guard let want else { return }
            restoreSpace(from: want.from, to: want.to, window: want.window, theftAt: want.theftAt)
        }
    }

    /// Before a Space restore's owner query, and again immediately before its focus: why focusing `window` would no
    /// longer restore Tim's Space (a fresh read finds his display back, or wanting another window, or cannot be
    /// taken, or the watch is sealed); nil: it still would. timQueue.
    func restorePending(_ window: Int) -> String? {
        let read = sample(via: "restore-check")
        lock.lock(); defer { lock.unlock() }
        if sealed { return "the guard is ending" }
        guard read != nil else { return "Tim's display could not be read" }
        guard let want = restoreWanted else { return "Tim's display no longer shows a Space the tree took it to" }
        return want.window == window ? nil : "the restore now wants window \(want.window)"
    }

    /// After main published the theft windows (each activation): while one lasts, reads every
    /// SpaceSampling.interval on watchQueue (until the poll stops for the guard's end); and reads now. main.
    func follow(via: String) {
        lock.lock()
        let t = uptime() - t0
        if !sealed && theftState.value.covers(since: t) {
            sampling.watch(at: t)
            if timer == nil && !pollStopped {
                let ticker = DispatchSource.makeTimerSource(flags: .strict, queue: watchQueue)
                ticker.schedule(deadline: .now() + SpaceSampling.interval, repeating: SpaceSampling.interval, leeway: .milliseconds(5))
                ticker.setEventHandler { [unowned self] in self.poll() }
                ticker.resume()
                timer = ticker
            }
        }
        lock.unlock()
        sample(via: via)
    }

    /// One poll; the last once no theft or grace window lasts, or the poll is stopped. watchQueue.
    private func poll() {
        sample(via: "poll")
        lock.lock(); defer { lock.unlock() }
        if pollStopped || sealed {
            timer?.cancel()
            timer = nil
        } else if !theftState.value.covers(since: uptime() - t0) {
            timer?.cancel()
            timer = nil
            sampling.unwatch()
        }
    }

    /// The guard's end, once its work is done and before the poll stops (endQueue, never main): while a change a read
    /// found has waited less than NoticeFeed.limit for its notification, waits (at most that long), so main, which
    /// keeps serving notifications, can take one still on its way before the seal. The poll goes on meanwhile: the
    /// wait leaves no gap in a theft or grace window.
    func awaitNotices() {
        let until = uptime() + NoticeFeed.limit
        while uptime() < until {
            lock.lock()
            let pending = !sealed && feed.pending(at: uptime() - t0)
            lock.unlock()
            guard pending else { return }
            usleep(10_000)
        }
    }

    /// The guard's end, once its work is done (endQueue, never main): the poll stops for good, and watchQueue is
    /// drained (for up to 1 s) so no poll is under way as the records are taken. Notifications and other reads are
    /// still taken and recorded until the seal; a theft or grace window still counts as watched, so the seal's read
    /// shows whether the reads stayed close enough.
    func stopPolling() {
        lock.lock()
        pollStopped = true
        timer?.cancel()
        timer = nil
        lock.unlock()
        let drained = DispatchSemaphore(value: 0)
        watchQueue.async { drained.signal() }
        _ = drained.wait(timeout: .now() + 1)
    }

    /// The seal, on main, in the turn that takes the summary's records (conclude): the last read of every display
    /// (a change since the last read, a breach, a gap or an unexplained notification is judged now; none if the watch
    /// never began), then, under the lock every read holds throughout, a change still waiting for its notification is
    /// a problem (NoticeFeed.seal), and nothing records any more. Main serves the notifications, so none can come
    /// between the seal and the records; one that comes after the seal is a problem (sample), never dropped
    /// unrecorded.
    func seal() {
        lock.lock()
        let begun = rows != nil
        lock.unlock()
        if begun { sample(via: "end") }
        lock.lock()
        if let late = feed.seal() { missed(late, sealing: true) }
        sealed = true
        timer?.cancel()
        timer = nil
        sampling.unwatch()
        lock.unlock()
    }

    /// The problem a change no notification followed makes (NoticeFeed): within the limit, or (`sealing`) before
    /// the seal. Lock held.
    private func missed(_ change: NoticeFeed.Change, sealing: Bool) {
        let space = map?.indexes[change.space].map { "Space \($0)" } ?? "a Space yabai did not list (SkyLight id \(change.space))"
        let display = change.display.map { "display \($0)" } ?? "Tim's display"
        let late = sealing ? "before the guard sealed its records" : "within \(NoticeFeed.limit) s"
        problem(String(format: "Space notifications are not arriving: a change to %@ at %.3f s after launch (%@, read by %@) got none %@, so the guard cannot check for unseen excursions",
                       space, change.at, display, change.via, late))
    }

    /// Asks yabai for its Space map again: for a Space it does not know, or a read that found no display holding
    /// Space 1. One request at a time, at most once a second. Lock held.
    private func refreshMap() {
        let now = uptime()
        guard !refreshing && now >= nextRefresh else { return }
        refreshing = true
        nextRefresh = now + 1
        mapQueue.async {
            tracked("Space map refresh") {
                let fresh = SpaceMap(yabai(["query", "--spaces"]))
                self.lock.lock()
                if let fresh { self.map = fresh }
                self.refreshing = false
                self.lock.unlock()
            }
        }
    }
}

/// macOS changed the active Space: what Tim's display shows, read now (an owner answer in flight no longer counts);
/// then the sweep. main.
func spaceChanged(input: Double?) {
    timEpoch.update { $0 += 1 }
    spaceWatch.sample(via: "notification", input: input)
    yabaiQueue.async { sweep("space-change") }
}

// MARK: - Activations (main thread)

/// GR2 (diagnostic only, it decides nothing): the app the last activation made frontmost (at first, the front app at
/// launch), its NSRunningApplication (none in the rig) and when, in seconds since launch. main.
var previousFront: (pid: pid_t, app: Any, running: NSRunningApplication?, at: Double)?

/// What the guard knows, without asking anyone, about the app that was frontmost before an activation at `t`
/// (seconds since launch): its record, whether it is in the tree (membership only), how long it had been frontmost,
/// and whether it has quit or is hidden (macOS activates another app when the frontmost one quits, hides or closes
/// its last window; the guard observes no window closes, so that last case is not known). null: none known. main.
@Sendable func previousFrontRecord(at t: Double) -> Any {
    guard let p = previousFront else { return NSNull() }
    return ["app": p.app, "tree": tree.contains(p.pid), "frontMs": ms(t - p.at),
            "terminated": p.running.map { $0.isTerminated as Any } ?? NSNull(),
            "hidden": p.running.map { $0.isHidden as Any } ?? NSNull()] as [String: Any]
}

/// `pid` became frontmost; `app` is its record and `running` its NSRunningApplication (none in the rig). `t`: uptime
/// when the activation arrived; `input`: the last HID input then (seconds since launch). Every activation's record
/// (activation, or reverted for Tim's app given focus back) carries sinceInputMs and previousFront.
func onActivation(_ pid: pid_t, app: Any, running: NSRunningApplication?, at t: Double, input: Double?) {
    let before = previousFrontRecord(at: t - t0)
    let inTree = tree.adopt(pid, via: "activation")
    timEpoch.update { $0 += 1 }  // an owner answer in flight no longer counts
    if let userFront = policy.userFront { _ = revalidateTarget(userFront) }
    let decision = policy.activation(pid: pid, inTree: inTree, at: t - t0, sinceInput: input.map { t - t0 - $0 })
    theftState.update { $0 = policy.window }
    let now = iso()
    let sinceInput: Any = input.map { ms(t - t0 - $0) } ?? NSNull()
    let context: [String: Any] = ["sinceInputMs": sinceInput, "previousFront": before]
    switch decision {
    case .restore(let to):
        if theft == nil {
            theft = ["app": app, "activatedAt": now, "t": t]
            theftPending.update { $0 = true }
        }
        // GR2 (item 4): Tim's app is activated at once, in this turn, after the same checks as the fallback's final
        // turn; the revert (his window by id once its owner is vouched for, unless focus is back by then) follows.
        let window = restoreTarget.value.window(for: to)
        var atOnce: [String: Any] = ["ok": false, "reason": NSNull()]
        var fronted: pid_t?  // the app the activation at once fronted: his, or a system modal in its place
        if stopping {
            atOnce["reason"] = "the guard's end began: not run"
        } else {
            switch finalActivation(to, method: "immediate") {
            case .activated(let ok):
                atOnce["ok"] = ok
                if ok { fronted = to }
            case .modal(let modal, let name, let ok):
                atOnce["ok"] = ok
                atOnce["modal"] = ["pid": Int(modal), "name": name] as [String: Any]
                if ok { fronted = modal }
            case .unwanted(let why), .refused(let why): atOnce["reason"] = why
            }
        }
        emit(context.merging(["event": "activation", "app": app, "tree": true, "decision": "restore", "to": Int(to),
                              "restoreWindow": window ?? NSNull(), "immediate": atOnce, "at": now]) { $1 })
        let (immediate, choice) = (fronted, policy.choice)
        schedule("revert to pid \(to)", on: restoreQueue) { revert(to: to, stolenAt: t, immediate: immediate, choice: choice) }
        observe(pid)
        yabaiQueue.async { sweep("activation") }
    case .restored(let latency):
        let last = lastRestore.value
        var record: [String: Any] = context.merging(["event": "reverted", "to": app, "restoredAt": now, "latencyMs": ms(latency),
                                                     "method": last.method, "window": last.window ?? NSNull()]) { $1 }
        if let theft {
            record["stolenBy"] = theft["app"]
            record["activatedAt"] = theft["activatedAt"]
        }
        reverted.append(record)
        emit(record)
    case .user, .tookOver:
        // GR2 (addendum 3): a takeover in a theft or grace window is his too: an open theft ends, its revert is no
        // longer wanted, and his display's Spaces from now on are his (SpacePolicy).
        let start = processStart(pid)
        restoreTarget.update { $0.userSwitched(to: pid, start: start) }
        timQueue.async { refreshTarget(pid) }
        emit(context.merging(["event": "activation", "app": app, "tree": false, "decision": "user",
                              "takeover": decision == .tookOver, "at": now]) { $1 })
    case .system:
        emit(context.merging(["event": "activation", "app": app, "tree": false, "decision": "system", "at": now]) { $1 })
    case .unrestorable:
        emit(context.merging(["event": "activation", "app": app, "tree": true, "decision": "unrestorable", "at": now]) { $1 })
        // GR2 item 6: no app or window to give focus back to; a system modal is re-fronted and Tim's display is
        // checked (display-check; review 3: no display is focused), unless he chooses an app first.
        if !stopping {
            let choice = policy.choice
            schedule("display check after pid \(pid)", on: restoreQueue) {
                let record = checkTimsDisplay(after: "the unrestorable activation of pid \(pid)") {
                    policy.choice == choice ? nil : "Tim chose an app since the activation: focus stays where he put it"
                }
                emit(record.merging(["event": "display-check", "pid": Int(pid)]) { $1 })
            }
        }
    case .afterGuard:
        break
    }
    if policy.pendingSince == nil && theft != nil {
        theft = nil
        theftPending.update { $0 = false }
    }
    previousFront = (pid, app, running, t - t0)
    spaceWatch.follow(via: "activation")
}

// MARK: - The scan (scanQueue)

func scanOnce() {
    let adopted = tree.scan()
    for pid in adopted { observe(pid) }
    if !adopted.isEmpty { yabaiQueue.async { sweep("attached") } }
}

// MARK: - End

/// Ends the guard (main): no new work starts; on endQueue, work in flight (reverts still queued included) settles
/// within its 3 s, then the final scan, sweep and focus read get their own 5 s (unless gui-launch is gone): the
/// tree's windows that the final sweep cannot locate are a problem. Then the helpers still running are ended; then,
/// while a change a read found still waits for its Space notification, the end waits for it (at most
/// NoticeFeed.limit, the poll still running); then the Space watch's poll stops (off main). Then, in one main-queue
/// turn, the watch takes its last read and is sealed, the summary's records are taken, and the summary and guard-end
/// are written. The main thread keeps serving events, Space notifications included, until that turn.
func finish(_ reason: String) {  // main
    guard !finishing else { return }
    finishing = true
    inFlight.close()
    scanTimer?.cancel()
    shownWatch.stop()
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
            shownQueue.sync { shownWatch.finalPass() }  // after the last adoption: its windows on screen are sighted
            sweep("final", final: true)
            if let why = windowListFailure.value { problem("the tree's windows could not be located at the guard's end: \(why)") }
            reportUnplacedAtEnd()
            focusAtEnd = windowFields(yabai(["query", "--windows", "--window"]) as? [String: Any])
            focusAtEnd["focusedDisplay"] = focusedDisplay() ?? NSNull()
            focusAtEnd["modal"] = modalRecord(systemModal())
        }
        spaceWatch.awaitNotices()
        spaceWatch.stopPolling()
        DispatchQueue.main.async { conclude(reason, orphaned: orphaned, focusAtEnd: focusAtEnd) }
    }
}

func conclude(_ reason: String, orphaned: Bool, focusAtEnd: [String: Any]) {  // main
    finished = true
    // The seal and the records, in this one turn: the Space watch takes its last read and records nothing after; the
    // end's work is settled (or reported unsettled); and main, which serves the activations and notifications, serves
    // none in between.
    spaceWatch.seal()
    let queries = yabaiQueries.value
    let records: [String: Any] = [
        "reverted": reverted, "moves": moves.value, "spaceRestores": spaceEvents.value, "problems": problems.value,
        "spaceHistory": spaceWatch.history, "ownerQueryTimeouts": ownerTimeouts.value, "windowFaults": windowFaults.value,
        "finalWindowList": finalWindowList.value.isEmpty ? NSNull() as Any : finalWindowList.value as Any,
        "yabaiQueries": queries.rows, "yabaiQueryStats": queries.stats,
        "nativeWindows": byWindow(nativeWindows.value),
        "nativePlacements": byWindow(nativePlacements.value),
        "exemptWindows": exemptRecords.value,
        "timSpace": ["atLaunch": timSpaceAtLaunch ?? NSNull(), "expected": spacePolicy.value.expected.map(spaceField) ?? NSNull()] as [String: Any],
    ]
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
        end["app"] = frontmost().app
        var summary = tree.summary
        summary.merge([
            "space": space, "guardSeconds": guardSeconds, "endReason": reason, "error": launchFailure ?? NSNull(),
            "fault": fault ?? NSNull(), "token": tokenHash,
            "frontAtLaunch": describe(frontAtLaunch), "frontAtEnd": describe(workspace.frontmostApplication),
            "userFront": describe(policy.userFront.flatMap { NSRunningApplication(processIdentifier: $0) }),
            "restorePending": theft != nil, "focusAtLaunch": focusAtLaunch, "focusAtEnd": end,
            "placement": allowCallerPlacement ? "caller" : "target",
        ]) { _, new in new }
        summary.merge(records) { _, new in new }
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

// MARK: - AppKit (GR1; not in the rig)

/// The guard's AppKit app (GR1-F1). AppKit's loop catches an Objective-C exception raised in it (an event, a timer, a
/// notification, a main-queue block) and hands it to reportException, whose own way with it (log it and go on, or
/// crash) hangs on the NSApplicationCrashOnExceptions default, which a preference or an argument can set. Here it
/// ends the guard at once whatever the defaults say (exceptionEnds).
final class GuardApplication: NSApplication {
    override func reportException(_ exception: NSException) {
        exceptionEnds(exception, inAppKit: true)
    }
}

/// The guard's AppKit app keeps AppKit from acting for it: what AppKit would open (it takes the arguments it does not
/// know, such as the launch's executable, for files to open) is ignored, and a quit Apple Event ends the guard as
/// SIGTERM does, with its check.
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {}

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        finish("signal")
        return .terminateCancel
    }
}

/// The app's delegate (NSApplication holds it weakly), its activation policy for the start record (null in the
/// rig), and the activity that keeps App Nap off the guard's timers.
var appDelegate: AppDelegate?
var appKitPolicy: Any = NSNull()
var appNapHold: NSObjectProtocol?

/// GR1: makes the guard an AppKit app that macOS never activates, after the GUI-session check and before SkyLight's
/// first read and the workspace observers; main then runs NSApplication's own loop (run()), not a bare run loop. A
/// plain process whose main thread ran the main run loop got its activations, which LaunchServices reports, and never
/// one Space notification (roblox's receipt 20261006T163321Z: four changes of Tim's display read, none by a
/// notification). yabai (dd84572) starts this way: NSApplicationLoad() (src/yabai.c:139), which creates the shared
/// NSApplication; its workspace observers (src/workspace.m:157-165, from src/yabai.c:295); then [NSApp run]
/// (src/yabai.c:350), which replaced a bare CFRunLoopRunInMode loop when its Space notifications stopped on macOS 26
/// (3861367, yabai #2680). [INFERENCE] The notifications then reach the guard too; NoticeFeed fails the check when
/// they do not. The shared app is the guard's own (GuardApplication), made before anything else asks AppKit for one,
/// so an Objective-C exception in its loop ends the guard at once; an app of another class is an error before
/// anything launches. The app is never activated: its policy is .prohibited (no Dock icon, no menu bar, no windows,
/// never frontmost), set before it runs, and a policy that does not take is an error before anything launches too.
/// AppKit opens nothing for it (NSTreatUnknownArgumentsAsOpen, and AppDelegate whatever that default says), and App
/// Nap does not slow its reads and reverts. Returns why the guard cannot run as that app; nil: it runs as one.
@MainActor func startAppKit() -> String? {
    UserDefaults.standard.register(defaults: ["NSTreatUnknownArgumentsAsOpen": "NO"])
    guard let app = GuardApplication.shared as? GuardApplication else {
        return "AppKit's app is not the guard's own, so an Objective-C exception in its loop could be logged and passed over: nothing was launched"
    }
    _ = app.setActivationPolicy(.prohibited)
    guard app.activationPolicy() == .prohibited else {
        return "AppKit would not make this process an app that can never be activated, so nothing was launched"
    }
    let delegate = AppDelegate()
    app.delegate = delegate
    appDelegate = delegate
    appKitPolicy = "prohibited"
    appNapHold = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                       reason: "gui-launch-guard times its reads and reverts in milliseconds")
    return nil
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

/// Runs `work` on startQueue, scheduled as work in flight, while the main thread keeps serving its queue. nil: the
/// guard began to end.
func awaitOffMain<T>(_ what: String, _ work: @escaping () -> T) -> T? {
    let result = Locked<T?>(nil)
    let scheduled = schedule(what, on: startQueue) {
        let value = work()
        result.update { $0 = value }
        DispatchQueue.main.async {}  // wakes the loop below
    }
    guard scheduled else { return nil }
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
    var timDisplay: Int?
    var focusedDisplay: Int?
    var map: SpaceMap?
    var error: String?
}

/// Before anything launches (startQueue): attach members already running join the tree; then Tim's front app
/// (outside the tree); yabai's window list, for the focused window and its Space (the restore target, if it is
/// that app's and outside the tree); and yabai's Spaces: the one his display shows, and each Space's SkyLight id.
/// Any query that fails, misses its deadline or answers unreadably is an error: every window row must say whether
/// it has focus, the focused one (at most one) which window it is, whose, and on which Space; no window having
/// focus is the only absence it accepts.
func takeBaseline(front: NSRunningApplication?) -> Baseline {
    var b = Baseline()
    if attaching { b.adopted = tree.scan() }
    if let front {
        let pid = front.processIdentifier
        let start = processStart(pid)
        b.frontIsTims = start != nil && !tree.adopt(pid, via: "baseline")
        if b.frontIsTims { b.target = RestoreTarget(pid: pid, start: start) }
    }
    let windowRead = queryReply(["query", "--windows"])
    switch windowRead.reply {
    case .exited(0, _):
        guard let windows = windowRead.value as? [[String: Any]] else {
            b.error = "yabai's window list is unreadable"
            return b
        }
        guard windows.allSatisfy({ $0["has-focus"] is Bool }) else {
            b.error = "yabai's window list is unreadable: a row does not say whether it has focus"
            return b
        }
        let focused = windows.filter { $0["has-focus"] as? Bool == true }
        guard focused.count <= 1 else {
            b.error = "yabai's window list is unreadable: \(focused.count) windows have focus"
            return b
        }
        if let w = focused.first {
            guard let id = (w["id"] as? NSNumber)?.intValue, let owner = (w["pid"] as? NSNumber)?.int32Value,
                  let space = (w["space"] as? NSNumber)?.intValue else {
                b.error = "yabai's window list is unreadable: the focused window's id, pid or Space is missing"
                return b
            }
            b.focused = windowFields(w)
            _ = b.target.verified(id, owner: owner, ownerStart: processStart(owner), ownerInTree: tree.adopt(owner, via: "baseline"),
                                  space: space)
        }
    case .exited(let code, _):
        b.error = "yabai -m query --windows exited \(code)"
        return b
    case .timedOut:
        b.error = "yabai -m query --windows did not answer within \(queryLimit) s"
        return b
    case .refused(let why):
        b.error = why
        return b
    }
    let spaceRead = queryReply(["query", "--spaces"])
    switch spaceRead.reply {
    case .exited(0, _):
        let spaces = spaceRead.value
        b.timSpace = timDisplaySpace(spaces)
        let shown = displays(spaces)
        b.timDisplay = shown.tims
        b.focusedDisplay = shown.focused
        b.map = SpaceMap(spaces)
        if b.timSpace == nil {
            b.error = "yabai's Spaces are unreadable or show none on Tim's display"
        } else if b.map == nil {
            b.error = "yabai's Spaces are unreadable: a Space without its id or index, or no Space 1"
        }
    case .exited(let code, _): b.error = "yabai -m query --spaces exited \(code)"
    case .timedOut: b.error = "yabai -m query --spaces did not answer within \(queryLimit) s"
    case .refused(let why): b.error = why
    }
    return b
}

let launchFront = rigTest ? nil : workspace.frontmostApplication

guard let baseline = awaitOffMain("the baseline", { takeBaseline(front: launchFront) }) else { dispatchMain() }
if let error = baseline.error { fail("no baseline, so nothing was launched: \(error)") }
frontAtLaunch = launchFront
if let front = launchFront { previousFront = (front.processIdentifier, describe(front), front, 0) }
focusAtLaunch = baseline.focused
// GR2 item 6, the before-state in the receipt: the front app, the focused window (or none), the focused display and
// Tim's, and any system modal on screen.
focusAtLaunch["app"] = describe(launchFront)
focusAtLaunch["focusedDisplay"] = baseline.focusedDisplay ?? NSNull()
focusAtLaunch["timDisplay"] = baseline.timDisplay ?? NSNull()
focusAtLaunch["modal"] = modalRecord(systemModal())
timSpaceAtLaunch = baseline.timSpace
timDisplay = baseline.timDisplay
policy = RestorePolicy(userFront: baseline.frontIsTims ? launchFront?.processIdentifier : nil, guardUntil: guardSeconds)
restoreTarget.update { $0 = baseline.target }
spacePolicy.update { $0 = SpacePolicy(expected: baseline.timSpace) }

if !rigTest {
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
    // GR1: the guard's own AppKit app, never activated, before SkyLight's first read and the observers (startAppKit),
    // and before anything else here (such as NSScreen) uses AppKit.
    if let why = MainActor.assumeIsolated({ startAppKit() }) { fail(why) }
}
focusAtLaunch["mainScreen"] = NSScreen.main?.localizedName ?? NSNull()
// GR1-F1/F2: an Objective-C exception that nothing catches (on any thread, or on main outside AppKit's loop; in the
// rig, any) ends the guard at once as well (exceptionEnds); AppKit's loop hands the ones it catches to
// GuardApplication. The runtime's own handler is the guard's: CoreFoundation's, which calls the one Foundation's
// NSSetUncaughtExceptionHandler sets, first reports the exception on stderr, a write that blocks when nobody drains
// stderr, before exceptionEnds could arm its watchdog. Foundation's handler is set too, in case CoreFoundation's
// comes back.
NSSetUncaughtExceptionHandler { exceptionEnds($0, inAppKit: false) }
_ = objc_setUncaughtExceptionHandler { exceptionEnds($0, inAppKit: false) }

// Tim's display, read directly from here on (the rig reads its stand-in file): the first read must show the Space
// yabai says it shows, or nothing launches.
let displayRows: () -> Any? = {
    if let displaysPath {
        return { (try? Data(contentsOf: URL(fileURLWithPath: displaysPath))).flatMap { try? JSONSerialization.jsonObject(with: $0) } }
    }
    if let read = SkyLight.displaySpaces { return read }
    fail("no baseline, so nothing was launched: SkyLight offers no read of the Space each display shows")
}()
guard let spaceMap = baseline.map, let firstRead = spaceWatch.begin(rows: displayRows, map: spaceMap),
      firstRead.index == baseline.timSpace else {
    fail("no baseline, so nothing was launched: SkyLight's record does not show Tim's display on Space \(baseline.timSpace.map { String($0) } ?? "?"), as yabai does")
}

if !rigTest {
    let center = workspace.notificationCenter
    center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil) { note in
        let t = uptime()
        let input = lastInput()
        guard !finished, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        onActivation(app.processIdentifier, app: describe(app), running: app, at: t, input: input)
    }
    center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: nil) { note in
        timEpoch.update { $0 += 1 }
        guard !finished, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        if tree.adopt(app.processIdentifier, via: "launch") { observe(app.processIdentifier) }
    }
    center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: nil) { _ in
        spaceChanged(input: lastInput())  // after the seal, a problem (SpaceWatch.sample): never dropped unrecorded
    }
    center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: nil) { _ in
        timEpoch.update { $0 += 1 }
        if mode != nil && !attaching && tree.hasRoots && !tree.anyAlive { finish("tree-exited") }
    }
}
let appsObservation: NSKeyValueObservation? = rigTest ? nil : workspace.observe(\.runningApplications, options: [.new]) { _, change in
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
    "restoreWindowSpace": baseline.target.windowSpace ?? NSNull(), "attach": attachRecord, "activationPolicy": appKitPolicy,
    "placement": allowCallerPlacement ? "caller" : "target",
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
// GR2: from the launch on, a tree window that comes on screen has the tree's windows re-checked.
shownWatch.start()

// MARK: - The rig (tests)

var rigRoot: pid_t?  // main
/// The app the rig's stand-ins last made frontmost (`tim`, `activate`, and the guard's own activations). main.
var rigFront: pid_t?

/// The record of an app in the rig, which has no NSRunningApplication for its stand-in processes.
@Sendable func rigApp(_ pid: pid_t) -> [String: Any] { ["pid": Int(pid), "name": "rig-\(pid)", "bundle": ""] }

/// --rig: each stdin line stands for something macOS would report, served on the main queue as its notifications
/// are: `root <pid>` (a process joins the tree, as --exec's does), `theft` and `back` (an activation of the root, or
/// of pid 1 standing in for an app outside the tree: the restore policy's decision and theft windows, without a
/// revert), `tim <pid> [<window> <space>]` (Tim's front app and its focused window on that Space, or no focused
/// window, as a baseline finds them: the app focus goes back to, the restore target, and the receipt's before-state
/// app, window and modal), `activate <pid> [ms]` (macOS reports `pid`
/// frontmost, his HID input `ms` before: the guard's whole activation path, reverts included; the rig's stand-in
/// activation, rig-activate, touches no app), `notify` (an active-Space change), `window <id>` (Accessibility reports
/// a window created), `sweep` (as at a tree activation), `poll` (one read of the windows on screen now, as the 100 ms
/// timer's, then rig-polled), `stall <s>` (watchQueue busy that long), `raise` (an Objective-C exception on main,
/// which in the rig, with no AppKit loop, nothing catches) and `end` (SIGTERM). main.
func rigCommand(_ words: [String]) {
    switch (words.first ?? "", words.count) {
    case ("root", 2):
        guard let pid = pid_t(words[1]) else { return }
        tree.addRoot(pid)
        rigRoot = pid
    case ("theft", 1), ("back", 1):
        let thief = words[0] == "theft"
        _ = policy.activation(pid: thief ? rigRoot ?? 0 : 1, inTree: thief, at: uptime() - t0)
        timEpoch.update { $0 += 1 }
        theftState.update { $0 = policy.window }
        spaceWatch.follow(via: "activation")
    case ("tim", 2), ("tim", 4):
        guard let pid = pid_t(words[1]) else { return }
        let focus = words.count == 4 ? Int(words[2]).flatMap { w in Int(words[3]).map { (window: w, shown: $0) } } : nil
        if words.count == 4 && focus == nil { return }
        let start = processStart(pid)
        let inTree = tree.contains(pid)
        policy = RestorePolicy(userFront: inTree ? nil : pid, guardUntil: guardSeconds)
        theftState.update { $0 = policy.window }
        restoreTarget.update { (target: inout RestoreTarget) -> Void in
            target = RestoreTarget(pid: inTree ? nil : pid, start: start)
            if let focus { _ = target.verified(focus.window, owner: pid, ownerStart: start, ownerInTree: inTree, space: focus.shown) }
        }
        rigFront = pid
        previousFront = (pid, rigApp(pid), nil, uptime() - t0)
        focusAtLaunch.merge(["app": rigApp(pid), "window": focus.map { $0.window as Any } ?? NSNull(),
                             "windowPid": focus == nil ? NSNull() as Any : Int(pid) as Any,
                             "modal": modalRecord(systemModal())]) { $1 }
    case ("activate", 2), ("activate", 3):
        guard let pid = pid_t(words[1]), !finished else { return }
        let t = uptime()
        let input = words.count == 3 ? Double(words[2]).map { t - t0 - $0 / 1000 } : nil
        rigFront = pid
        onActivation(pid, app: rigApp(pid), running: nil, at: t, input: input)
    case ("notify", 1):
        spaceChanged(input: nil)
    case ("window", 2):
        guard let id = Int(words[1]) else { return }
        let seen = uptime()
        sighted(id, at: seen, via: "ax-created")
        yabaiQueue.async { park(id, seen: seen, via: "ax-created") }
    case ("sweep", 1):
        yabaiQueue.async { sweep("activation") }
    case ("poll", 1):
        shownQueue.async {
            shownWatch.pollNow()
            emit(["event": "rig-polled"])
        }
    case ("stall", 2):
        guard let seconds = Double(words[1]) else { return }
        watchQueue.async { usleep(UInt32(seconds * 1_000_000)) }
    case ("raise", 1):
        NSException(name: NSExceptionName("GuiLaunchRigException"), reason: "raised by the rig", userInfo: nil).raise()
    case ("end", 1):
        finish("signal")
    default:
        break
    }
}

if rigTest {
    Thread {
        while let line = readLine() {
            let words = line.split(separator: " ").map(String.init)
            DispatchQueue.main.async { rigCommand(words) }
        }
    }.start()
}

Timer.scheduledTimer(withTimeInterval: guardSeconds, repeats: false) { _ in finish("timeout") }
// GR1: NSApplication's own loop (startAppKit), which serves the main run loop and queue as RunLoop.main.run() does,
// and the AppKit events macOS's Space notifications come through; the rig has no AppKit app.
if rigTest {
    RunLoop.main.run()
} else {
    MainActor.assumeIsolated { NSApplication.shared.run() }
}
