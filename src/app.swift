import AppKit
import Foundation
import UserNotifications

// MARK: - Paths & tuning

let homeURL = FileManager.default.homeDirectoryForCurrentUser
let claudeURL = homeURL.appendingPathComponent(".claude")
let sessionsURL = claudeURL.appendingPathComponent("sessions")
let projectsURL = claudeURL.appendingPathComponent("projects")

// Transcripts run to tens of MB, so only the ends are parsed: the latest usage
// record lives at the tail, the model attachment usually in the first turns.
let tailBytes = 512 * 1024
let headBytes = 256 * 1024
let defaultInterval: TimeInterval = 180

// MARK: - Model

struct Session {
    var pid: Int
    var sessionId: String
    var cwd: String
    var name: String
    var status: String
    var kind: String
    var version: String
    var updatedAt: Date?
    var contextTokens: Int = 0
    var contextLimit: Int = 200_000
    var modelName: String = "unknown"
    var costUSD: Double = 0
    var tty: String = ""
    var entrypoint: String = ""
    var ownerApp: URL?
    var ownerBundleId: String?
    // Only the CLI writes a status field; other front-ends register without one,
    // so their busy/idle state is genuinely unknown rather than idle.
    var hasStatus = false
    var transcript: URL?

    var percent: Double {
        guard contextLimit > 0 else { return 0 }
        return min(100, Double(contextTokens) / Double(contextLimit) * 100)
    }
}

// MARK: - Reading

func processAlive(_ pid: Int) -> Bool {
    if pid <= 0 { return false }
    if kill(pid_t(pid), 0) == 0 { return true }
    return errno == EPERM   // exists, just not ours to signal
}

func readTail(_ url: URL, _ maxBytes: Int) -> String {
    guard let fh = try? FileHandle(forReadingFrom: url) else { return "" }
    defer { try? fh.close() }
    guard let size = try? fh.seekToEnd() else { return "" }
    let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
    try? fh.seek(toOffset: start)
    guard let data = try? fh.readToEnd() else { return "" }
    var s = String(decoding: data, as: UTF8.self)
    // the first line is probably cut in half
    if start > 0, let nl = s.firstIndex(of: "\n") { s = String(s[s.index(after: nl)...]) }
    return s
}

func readHead(_ url: URL, _ maxBytes: Int) -> String {
    guard let fh = try? FileHandle(forReadingFrom: url) else { return "" }
    defer { try? fh.close() }
    guard let data = try? fh.read(upToCount: maxBytes) else { return "" }
    var s = String(decoding: data, as: UTF8.self)
    if let nl = s.lastIndex(of: "\n") { s = String(s[..<nl]) }
    return s
}

func jsonObject<S: StringProtocol>(_ s: S) -> [String: Any]? {
    guard let d = s.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
}

func transcriptURL(_ sessionId: String) -> URL? {
    let fm = FileManager.default
    guard let dirs = try? fm.contentsOfDirectory(at: projectsURL, includingPropertiesForKeys: nil)
    else { return nil }
    var best: (URL, Date)?
    for d in dirs {
        let p = d.appendingPathComponent("\(sessionId).jsonl")
        guard let attrs = try? fm.attributesOfItem(atPath: p.path),
              let m = attrs[.modificationDate] as? Date else { continue }
        if best == nil || m > best!.1 { best = (p, m) }
    }
    return best?.0
}

struct Facts {
    var tokens = 0
    var modelId: String?
    var modelName: String?
}

func extractModel(_ obj: [String: Any]) -> (String?, String?)? {
    guard let att = obj["attachment"] as? [String: Any],
          (att["type"] as? String) == "model",
          let ident = att["identity"] as? [String: Any] else { return nil }
    return (ident["modelId"] as? String, ident["marketingName"] as? String)
}

func scanTranscript(_ url: URL) -> Facts {
    var f = Facts()

    for line in readTail(url, tailBytes).split(separator: "\n").reversed() {
        // cheap prefilter — most lines are tool output and can't match
        let interesting = line.contains("\"usage\"") || line.contains("\"attachment\"")
        guard interesting, let obj = jsonObject(line) else { continue }

        // Latest main-thread assistant turn. Sidechain turns are subagents and
        // have their own context, so they must not stand in for this session's.
        if f.tokens == 0,
           (obj["type"] as? String) == "assistant",
           (obj["isSidechain"] as? Bool) != true,
           let msg = obj["message"] as? [String: Any],
           let usage = msg["usage"] as? [String: Any] {
            let input = usage["input_tokens"] as? Int ?? 0
            let created = usage["cache_creation_input_tokens"] as? Int ?? 0
            let read = usage["cache_read_input_tokens"] as? Int ?? 0
            let output = usage["output_tokens"] as? Int ?? 0
            f.tokens = input + created + read + output
        }
        if f.modelId == nil, let (id, name) = extractModel(obj) {
            f.modelId = id
            f.modelName = name
        }
        if f.tokens > 0 && f.modelId != nil { break }
    }

    let head = readHead(url, headBytes)
    if f.modelId == nil {
        for line in head.split(separator: "\n") {
            guard line.contains("\"attachment\""), let obj = jsonObject(line),
                  let (id, name) = extractModel(obj) else { continue }
            f.modelId = id
            f.modelName = name
        }
    }
    return f
}

// The transcript's `model` field drops the [1m] suffix, so the model attachment
// is the only local signal for a 1M window. Fall back to what we've observed.
func contextLimit(_ modelId: String?, observed: Int) -> Int {
    if let id = modelId, id.contains("[1m]") { return 1_000_000 }
    if observed > 200_000 { return 1_000_000 }
    return 200_000
}

// MARK: - Status line cache
//
// cc-widget-statusline drops these while any session renders. They carry
// Claude Code's own numbers, so they beat anything derived from a transcript.

let widgetCacheURL = claudeURL.appendingPathComponent("widget-cache")

func intOf(_ any: Any?) -> Int? {
    if let i = any as? Int { return i }
    if let d = any as? Double { return Int(d.rounded()) }
    return nil
}

struct Limits {
    var fiveHourPct: Int?
    var fiveHourResets: Date?
    var sevenDayPct: Int?
    var sevenDayResets: Date?
    var updatedAt: Date?
}

func loadJSON(_ url: URL) -> [String: Any]? {
    guard let d = try? Data(contentsOf: url) else { return nil }
    return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
}

func loadLimits() -> Limits? {
    guard let o = loadJSON(widgetCacheURL.appendingPathComponent("limits.json")) else { return nil }
    var l = Limits()
    l.fiveHourPct = intOf(o["five_hour_pct"])
    l.sevenDayPct = intOf(o["seven_day_pct"])
    if let t = intOf(o["five_hour_resets_at"]) { l.fiveHourResets = Date(timeIntervalSince1970: Double(t)) }
    if let t = intOf(o["seven_day_resets_at"]) { l.sevenDayResets = Date(timeIntervalSince1970: Double(t)) }
    if let t = intOf(o["updated_at"]) { l.updatedAt = Date(timeIntervalSince1970: Double(t)) }
    return l
}

struct Snapshot {
    var name = ""
    var model = ""
    var tokens = 0
    var size = 0
    var cost = 0.0
}

func loadSnapshot(_ sessionId: String) -> Snapshot? {
    guard let o = loadJSON(widgetCacheURL.appendingPathComponent("session-\(sessionId).json"))
    else { return nil }
    return Snapshot(
        name: o["session_name"] as? String ?? "",
        model: o["model"] as? String ?? "",
        tokens: intOf(o["context_tokens"]) ?? 0,
        size: intOf(o["context_size"]) ?? 0,
        cost: o["cost_usd"] as? Double ?? 0
    )
}

// Just the busy/idle field, re-read without the cost of a full collect.
func registryStatuses() -> [String: (status: String, updatedAt: Date?)] {
    var out: [String: (status: String, updatedAt: Date?)] = [:]
    guard let files = try? FileManager.default.contentsOfDirectory(
        at: sessionsURL, includingPropertiesForKeys: nil) else { return out }
    for file in files where file.pathExtension == "json" {
        guard let data = try? Data(contentsOf: file),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let pid = o["pid"] as? Int, processAlive(pid),
              let sid = o["sessionId"] as? String else { continue }
        out[sid] = (o["status"] as? String ?? "",
                    (o["updatedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) })
    }
    return out
}

// MARK: - Bringing a session to the front

// iTerm2 and Terminal.app can be asked to select the tab on a given tty. For
// anything else the best available answer is to raise its application.
func revealScript(bundleId: String?, tty: String) -> String? {
    guard !tty.isEmpty else { return nil }
    switch bundleId {
    case "com.googlecode.iterm2":
        return """
        tell application id "com.googlecode.iterm2"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if tty of s is "/dev/\(tty)" then
                  select w
                  select t
                  select s
                  activate
                  return "ok"
                end if
              end repeat
            end repeat
          end repeat
        end tell
        return "missing"
        """
    case "com.apple.Terminal":
        return """
        tell application id "com.apple.Terminal"
          repeat with w in windows
            repeat with t in tabs of w
              if tty of t is "/dev/\(tty)" then
                set selected tab of w to t
                set index of w to 1
                activate
                return "ok"
              end if
            end repeat
          end repeat
        end tell
        return "missing"
        """
    default:
        return nil
    }
}

// MARK: - Focus tracking

struct ProcEntry {
    var ppid = 0
    var tty = ""
    var command = ""
}

func processTable() -> [Int: ProcEntry] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-Ao", "pid=,ppid=,tty=,comm="]
    let pipe = Pipe()
    p.standardOutput = pipe
    guard (try? p.run()) != nil else { return [:] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()

    var table: [Int: ProcEntry] = [:]
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
        // the command is a path and may contain spaces, so only split off the first three
        let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard fields.count >= 4, let pid = Int(fields[0]), let ppid = Int(fields[1]) else { continue }
        // split stops at maxSplits and hands back the rest verbatim, padding
        // included — an untrimmed path is read as relative and resolves nowhere
        table[pid] = ProcEntry(ppid: ppid,
                               tty: fields[2] == "??" ? "" : String(fields[2]),
                               command: fields[3].trimmingCharacters(in: .whitespaces))
    }
    return table
}

// Walks up from the session process until something living in an .app bundle
// turns up: the terminal hosting it, or the desktop app running it directly.
func owningApp(_ pid: Int, _ table: [Int: ProcEntry]) -> URL? {
    var current = pid
    for _ in 0..<12 {
        guard let entry = table[current] else { return nil }
        if let r = entry.command.range(of: ".app/Contents/MacOS/") {
            let bundle = String(entry.command[..<r.lowerBound]) + ".app"
            // never hand Launch Services something that isn't there
            if bundle.hasPrefix("/"), FileManager.default.fileExists(atPath: bundle) {
                return URL(fileURLWithPath: bundle)
            }
            return nil
        }
        current = entry.ppid
        if current <= 1 { return nil }
    }
    return nil
}

// Apple Events are the only way to learn which tab is in front; nothing on disk
// tracks it. Returns nil whenever the front app isn't a terminal we can ask.
func focusedTTY() -> String? {
    guard let bundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return nil }
    let source: String
    switch bundleId {
    case "com.googlecode.iterm2":
        source = "tell application id \"com.googlecode.iterm2\" to tell current session of current window to get tty"
    case "com.apple.Terminal":
        source = "tell application id \"com.apple.Terminal\" to get tty of selected tab of front window"
    default:
        return nil
    }
    var err: NSDictionary?
    guard let script = NSAppleScript(source: source) else { return nil }
    let result = script.executeAndReturnError(&err)
    guard err == nil, let raw = result.stringValue else { return nil }
    return raw.hasPrefix("/dev/") ? String(raw.dropFirst(5)) : raw
}

func collect() -> [Session] {
    let fm = FileManager.default
    guard let files = try? fm.contentsOfDirectory(at: sessionsURL, includingPropertiesForKeys: nil)
    else { return [] }

    let table = processTable()
    var byId: [String: Session] = [:]
    for file in files where file.pathExtension == "json" {
        guard let data = try? Data(contentsOf: file),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let pid = o["pid"] as? Int, processAlive(pid),
              let sid = o["sessionId"] as? String else { continue }

        var s = Session(
            pid: pid,
            sessionId: sid,
            cwd: o["cwd"] as? String ?? "",
            name: o["name"] as? String ?? String(sid.prefix(8)),
            status: o["status"] as? String ?? "",
            kind: o["kind"] as? String ?? "",
            version: o["version"] as? String ?? "",
            updatedAt: (o["updatedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        )
        s.tty = table[pid]?.tty ?? ""
        s.ownerApp = owningApp(pid, table)
        s.ownerBundleId = s.ownerApp.flatMap { Bundle(url: $0)?.bundleIdentifier }
        s.entrypoint = o["entrypoint"] as? String ?? "cli"
        s.hasStatus = !s.status.isEmpty
        s.transcript = transcriptURL(sid)
        // front-ends that omit updatedAt still touch their transcript
        if s.updatedAt == nil, let t = s.transcript,
           let m = (try? fm.attributesOfItem(atPath: t.path))?[.modificationDate] as? Date {
            s.updatedAt = m
        }
        if let snap = loadSnapshot(sid) {
            s.contextTokens = snap.tokens
            if snap.size > 0 { s.contextLimit = snap.size }
            if !snap.model.isEmpty { s.modelName = snap.model }
            s.costUSD = snap.cost
            if !snap.name.isEmpty { s.name = snap.name }
            // a resumed session reports 0 until it renders its first turn
            if snap.tokens == 0, let t = s.transcript {
                let f = scanTranscript(t)
                if f.tokens > 0 { s.contextTokens = f.tokens }
            }
        } else if let t = s.transcript {
            // sessions that started before the status line collector existed
            let f = scanTranscript(t)
            s.contextTokens = f.tokens
            s.contextLimit = contextLimit(f.modelId, observed: f.tokens)
            s.modelName = f.modelName ?? f.modelId ?? "unknown"
        }
        // a resumed session can leave an older pid file behind
        if let prev = byId[sid], (prev.updatedAt ?? .distantPast) > (s.updatedAt ?? .distantPast) { continue }
        byId[sid] = s
    }

    return byId.values.sorted { $0.percent > $1.percent }
}

// MARK: - Formatting

func fmtTokens(_ n: Int) -> String {
    if n >= 1_000_000 {
        let m = Double(n) / 1_000_000
        return m >= 10 ? String(format: "%.0fM", m) : String(format: "%.2fM", m)
    }
    if n >= 1_000 { return "\(Int((Double(n) / 1000).rounded()))k" }
    return "\(n)"
}

func bar(_ pct: Double, width: Int = 10) -> String {
    let filled = max(0, min(width, Int((pct / 100 * Double(width)).rounded())))
    return String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
}

func ago(_ d: Date?) -> String {
    guard let d else { return "" }
    let s = max(0, Int(Date().timeIntervalSince(d)))
    if s < 60 { return "\(s)s ago" }
    if s < 3600 { return "\(s / 60)m ago" }
    if s < 86400 { return "\(s / 3600)h ago" }
    return "\(s / 86400)d ago"
}

func tildePath(_ p: String) -> String {
    let h = homeURL.path
    if p == h { return "~" }
    if p.hasPrefix(h + "/") { return "~" + p.dropFirst(h.count) }
    return p
}

// CJK and emoji occupy two terminal-ish cells; plain .count would misalign columns.
func displayWidth(_ s: String) -> Int {
    var w = 0
    for u in s.unicodeScalars {
        switch u.value {
        case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF,
             0xFE30...0xFE6F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
             0x1F300...0x1FAFF, 0x20000...0x3FFFD:
            w += 2
        default:
            w += 1
        }
    }
    return w
}

func pad(_ s: String, _ n: Int) -> String {
    var out = s
    while displayWidth(out) > n { out = String(out.dropLast()) }
    return out + String(repeating: " ", count: max(0, n - displayWidth(out)))
}

func until(_ d: Date?) -> String {
    guard let d else { return "" }
    let s = Int(d.timeIntervalSinceNow)
    if s <= 0 { return "resetting" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86400 { return "\(s / 3600)h \((s % 3600) / 60)m" }
    return "\(s / 86400)d \((s % 86400) / 3600)h"
}

func tabbed(_ stops: [CGFloat]) -> NSParagraphStyle {
    let p = NSMutableParagraphStyle()
    p.tabStops = stops.map { NSTextTab(textAlignment: .left, location: $0, options: [:]) }
    p.defaultTabInterval = 40
    return p
}

let sessionColumns = tabbed([30, 215, 315, 362])
let limitColumns = tabbed([30, 315, 362])

func sourceLabel(_ entrypoint: String) -> String {
    switch entrypoint {
    case "claude-desktop": return "desktop app"
    case "": return "unknown"
    default: return entrypoint
    }
}

func heatColor(_ pct: Double) -> NSColor {
    if pct >= 80 { return .systemRed }
    if pct >= 60 { return .systemOrange }
    return .labelColor
}

func mono(_ text: String, size: CGFloat = 12, color: NSColor = .labelColor, bold: Bool = false) -> NSMutableAttributedString {
    NSMutableAttributedString(string: text, attributes: [
        .font: NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .semibold : .regular),
        .foregroundColor: color,
    ])
}

// MARK: - Controller

final class Controller: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var sessions: [Session] = []
    private var limits: Limits?
    private var focusedTty: String?
    private var watchSource: DispatchSourceFileSystemObject?
    private var watchFD: Int32 = -1
    private var watchDebounce: DispatchWorkItem?
    private var registryWatch: DispatchSourceFileSystemObject?
    private var registryFD: Int32 = -1
    private var registryDebounce: DispatchWorkItem?
    private var focusTimer: Timer?
    // NSAppleScript isn't reentrant, so keep every send on one serial queue and
    // off the main thread — a wedged terminal must not freeze the menu bar.
    private let focusQueue = DispatchQueue(label: "focus")

    private var followFocus: Bool {
        UserDefaults.standard.object(forKey: "followFocus") as? Bool ?? true
    }

    private var focusedSession: Session? {
        guard followFocus, let t = focusedTty, !t.isEmpty else { return nil }
        return sessions.first { $0.tty == t }
    }
    private var timer: Timer?
    private var menuOpen = false

    private var interval: TimeInterval {
        let v = UserDefaults.standard.double(forKey: "refreshInterval")
        return v > 0 ? v : defaultInterval
    }

    override init() {
        super.init()
        menu.delegate = self
        item.menu = menu
        // lets macOS remember where the icon was dragged to (e.g. out of Vanilla's hidden zone)
        item.autosaveName = "claude_context_monitor"
        render()
        refresh()
        startTimer()
        startFocusTimer()
        startWatching()
        startWatchingRegistry()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: - reacting to the collector

    // The status line writes on every render, so react to the cache directory
    // instead of waiting out the refresh interval. Alerts then land within a
    // second of a session crossing a threshold.
    private func startWatching() {
        try? FileManager.default.createDirectory(at: widgetCacheURL, withIntermediateDirectories: true)
        watchFD = open(widgetCacheURL.path, O_EVTONLY)
        guard watchFD >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: watchFD, eventMask: [.write, .attrib], queue: .main)
        src.setEventHandler { [weak self] in self?.scheduleLightRefresh() }
        src.setCancelHandler { [weak self] in
            if let fd = self?.watchFD, fd >= 0 { close(fd) }
        }
        src.resume()
        watchSource = src
    }

    // Hooks rewrite the registry on every tool call, so busy/idle can follow
    // along instead of waiting out the refresh interval.
    private func startWatchingRegistry() {
        registryFD = open(sessionsURL.path, O_EVTONLY)
        guard registryFD >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: registryFD, eventMask: [.write, .attrib], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            self.registryDebounce?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.statusRefresh() }
            self.registryDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
        src.setCancelHandler { [weak self] in
            if let fd = self?.registryFD, fd >= 0 { close(fd) }
        }
        src.resume()
        registryWatch = src
    }

    private func statusRefresh() {
        let snapshot = registryStatuses()
        // a session appearing or leaving needs pid, tty and context too
        guard Set(snapshot.keys) == Set(sessions.map(\.sessionId)) else {
            refresh()
            return
        }
        for i in sessions.indices {
            guard let entry = snapshot[sessions[i].sessionId] else { continue }
            sessions[i].status = entry.status
            sessions[i].hasStatus = !entry.status.isEmpty
            if let at = entry.updatedAt { sessions[i].updatedAt = at }
        }
        render()
        if menuOpen { rebuild() }
    }

    private func scheduleLightRefresh() {
        watchDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.lightRefresh() }
        watchDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // Re-reads only the cache files for sessions we already know about: no ps,
    // no directory walk, no transcript parsing. Cheap enough to run per write.
    private func lightRefresh() {
        let known = Set(sessions.map(\.sessionId))
        var seen = Set<String>()
        if let files = try? FileManager.default.contentsOfDirectory(atPath: widgetCacheURL.path) {
            for f in files where f.hasPrefix("session-") && f.hasSuffix(".json") {
                seen.insert(String(f.dropFirst(8).dropLast(5)))
            }
        }
        // a session we have never seen needs the full pass to get pid/tty/status
        if !seen.subtracting(known).isEmpty {
            refresh()
            return
        }

        var updated = sessions
        for i in updated.indices {
            guard let snap = loadSnapshot(updated[i].sessionId) else { continue }
            if snap.tokens > 0 { updated[i].contextTokens = snap.tokens }
            if !snap.model.isEmpty { updated[i].modelName = snap.model }
            if snap.size > 0 { updated[i].contextLimit = snap.size }
            updated[i].costUSD = snap.cost
            if !snap.name.isEmpty { updated[i].name = snap.name }
        }
        sessions = updated.sorted { $0.percent > $1.percent }
        limits = loadLimits()
        render()
        if menuOpen { rebuild() }
        checkAlerts()
    }

    // MARK: - threshold alerts

    private var alertsEnabled: Bool {
        UserDefaults.standard.object(forKey: "alertsEnabled") as? Bool ?? true
    }

    private var alertContext: Bool {
        UserDefaults.standard.object(forKey: "alertContext") as? Bool ?? true
    }

    private var alertLimit: Bool {
        UserDefaults.standard.object(forKey: "alertLimit") as? Bool ?? true
    }

    private var usePushHook: Bool {
        UserDefaults.standard.object(forKey: "usePushHook") as? Bool ?? true
    }

    private var alertLevels: [Int] {
        let stored = UserDefaults.standard.array(forKey: "alertLevels") as? [Int] ?? []
        return stored.isEmpty ? [80, 90, 95] : stored.sorted()
    }

    private var alertState: [String: Int] {
        get { UserDefaults.standard.dictionary(forKey: "alertState") as? [String: Int] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "alertState") }
    }

    private func checkAlerts() {
        guard alertsEnabled else { return }
        var state = alertState
        var changed = false

        func crossedLevel(_ key: String, _ percent: Int) -> Int? {
            let alreadySent = state[key] ?? 0
            let crossed = alertLevels.filter { percent >= $0 }.max() ?? 0
            if crossed == 0 {
                // dropped back below the lowest level (a compact, say) — re-arm
                if alreadySent != 0 { state[key] = nil; changed = true }
                return nil
            }
            guard crossed > alreadySent else { return nil }
            state[key] = crossed
            changed = true
            return crossed
        }

        if alertContext {
            for s in sessions {
                let percent = Int(s.percent.rounded())
                guard let level = crossedLevel("ctx-" + s.sessionId, percent) else { continue }
                notify("컨텍스트 \(percent)% · \(s.name)", payload: [
                    "kind": "context",
                    "level": level,
                    "percent": percent,
                    "session": [
                        "id": s.sessionId,
                        "name": s.name,
                        "cwd": s.cwd,
                        "model": s.modelName,
                        "entrypoint": s.entrypoint,
                        "tokens": s.contextTokens,
                        "window": s.contextLimit,
                    ],
                ])
            }
        }
        if alertLimit, let week = limits?.sevenDayPct,
           let level = crossedLevel("limit-7d", week) {
            var payload: [String: Any] = [
                "kind": "limit",
                "level": level,
                "percent": week,
                "window": "seven_day",
            ]
            if let resets = limits?.sevenDayResets {
                payload["resets_at"] = Int(resets.timeIntervalSince1970)
            }
            notify("주간 한도 \(week)% 사용", payload: payload)
        }

        // forget sessions whose snapshot the collector has already aged out
        for key in state.keys where key.hasPrefix("ctx-") {
            let id = String(key.dropFirst(4))
            let snap = widgetCacheURL.appendingPathComponent("session-\(id).json")
            if !FileManager.default.fileExists(atPath: snap.path) {
                state[key] = nil
                changed = true
            }
        }
        if changed { alertState = state }
    }

    private var notifyHook: URL? {
        let fm = FileManager.default
        if let custom = UserDefaults.standard.string(forKey: "notifyHook"), !custom.isEmpty {
            let u = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
            return fm.isExecutableFile(atPath: u.path) ? u : nil
        }
        let conventional = homeURL.appendingPathComponent(".claude/widget-notify")
        return fm.isExecutableFile(atPath: conventional.path) ? conventional : nil
    }

    // The push script is the extension point: it receives the human-readable
    // message as $1 and a JSON object on stdin, and can do whatever it likes
    // with them. Keeping it a script rather than a built-in webhook is what lets
    // this app make no network requests of its own.
    private func notify(_ message: String, payload: [String: Any]) {
        if usePushHook, let hook = notifyHook {
            var full = payload
            full["message"] = message
            full["at"] = Int(Date().timeIntervalSince1970)

            let p = Process()
            p.executableURL = hook
            p.arguments = [message]
            let stdin = Pipe()
            p.standardInput = stdin
            if (try? p.run()) != nil {
                // small enough to sit in the pipe buffer, so this never blocks
                // even when the script ignores stdin entirely
                if var data = try? JSONSerialization.data(withJSONObject: full) {
                    data.append(0x0A)
                    try? stdin.fileHandleForWriting.write(contentsOf: data)
                }
                try? stdin.fileHandleForWriting.close()
            }
        }
        let content = UNMutableNotificationContent()
        content.title = "Claude Code"
        content.body = message
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private func startFocusTimer() {
        focusTimer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(
            self, name: NSWorkspace.didActivateApplicationNotification, object: nil)
        guard followFocus else {
            focusedTty = nil
            render()
            return
        }
        // App switches arrive as a notification, so they need no polling at all.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)

        // Switching tabs *within* a terminal fires nothing, so that case still
        // polls — cheap, since focusedTTY() checks the front app before it sends
        // an Apple Event and does nothing when it isn't a terminal.
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.updateFocus() }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        focusTimer = t
        updateFocus()
    }

    @objc private func appActivated() { updateFocus() }

    private func updateFocus() {
        focusQueue.async { [weak self] in
            let tty = focusedTTY()
            DispatchQueue.main.async {
                guard let self, self.focusedTty != tty else { return }
                self.focusedTty = tty
                self.render()
                if self.menuOpen { self.rebuild() }
                self.checkAlerts()
            }
        }
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.refresh() }
        t.tolerance = interval * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = collect()
            let lim = loadLimits()
            DispatchQueue.main.async {
                guard let self else { return }
                self.sessions = found
                self.limits = lim
                self.render()
                if self.menuOpen { self.rebuild() }
            }
        }
    }

    // MARK: status bar title

    private func render() {
        let title: NSMutableAttributedString
        if sessions.isEmpty {
            title = mono("⚡ –", size: 12, color: .secondaryLabelColor)
        } else {
            let focused = focusedSession
            // focused session when the user is looking at one, worst case otherwise
            let shown = focused?.percent ?? (sessions.map(\.percent).max() ?? 0)
            title = mono("⚡ ", size: 12)
            if focused != nil { title.append(mono("▸", size: 12, color: .secondaryLabelColor)) }
            title.append(mono(String(format: "%.0f%%", shown), size: 12, color: heatColor(shown), bold: true))
            // Only CLI sessions report busy/idle. Anything else has no pid to
            // ask, so it is counted apart rather than guessed at.
            let known = sessions.filter(\.hasStatus)
            let busy = known.filter { $0.status == "busy" }.count
            let unknown = sessions.count - known.count
            title.append(mono(" · ", size: 12, color: .tertiaryLabelColor))
            title.append(mono("\(busy)/\(known.count)", size: 12, color: .labelColor))
            if unknown > 0 {
                title.append(mono(" ◌\(unknown)", size: 12, color: .tertiaryLabelColor))
            }
        }
        if let week = limits?.sevenDayPct {
            title.append(mono("  7d ", size: 12, color: .tertiaryLabelColor))
            title.append(mono("\(week)%", size: 12, color: heatColor(Double(week)), bold: true))
        }
        item.button?.attributedTitle = title
    }

    // MARK: menu

    func menuWillOpen(_ menu: NSMenu) {
        menuOpen = true
        rebuild()      // show what we have immediately
        refresh()      // then update in place when fresh data lands
    }

    func menuDidClose(_ menu: NSMenu) { menuOpen = false }

    private func limitRow(_ label: String, _ percent: Int?, _ resets: Date?) -> NSAttributedString {
        let line = NSMutableAttributedString()
        line.append(mono("   " + label, size: 12, color: .secondaryLabelColor))
        if let percent {
            let heat = heatColor(Double(percent))
            line.append(mono("\t\(percent)%", size: 12, color: heat, bold: true))
            line.append(mono("\t" + bar(Double(percent)), size: 12, color: heat))
            if let resets {
                line.append(mono("  resets in " + until(resets), size: 10, color: .secondaryLabelColor))
            }
        } else {
            line.append(mono("\tno data yet", size: 12, color: .tertiaryLabelColor))
        }
        line.addAttribute(.paragraphStyle, value: limitColumns, range: NSRange(location: 0, length: line.length))
        return line
    }

    private func addLimitsSection() {
        let head = NSMenuItem()
        let title = mono("USAGE LIMITS", size: 10, color: .secondaryLabelColor, bold: true)
        // the numbers only move while some session is rendering, so say how old they are
        if let at = limits?.updatedAt {
            let stale = Date().timeIntervalSince(at) > 900
            title.append(mono("  " + ago(at), size: 10,
                              color: stale ? .systemOrange : .tertiaryLabelColor))
        }
        head.attributedTitle = title
        head.isEnabled = false
        menu.addItem(head)

        if limits == nil {
            let none = NSMenuItem()
            none.attributedTitle = mono("   run a Claude Code session to populate", size: 11, color: .tertiaryLabelColor)
            none.isEnabled = false
            menu.addItem(none)
        } else {
            for (label, p, r) in [("5-hour", limits?.fiveHourPct, limits?.fiveHourResets),
                                  ("7-day", limits?.sevenDayPct, limits?.sevenDayResets)] {
                let it = NSMenuItem()
                it.attributedTitle = limitRow(label, p, r)
                it.isEnabled = false
                menu.addItem(it)
            }
        }
        menu.addItem(.separator())
    }

    private func rebuild() {
        menu.removeAllItems()
        addLimitsSection()

        let header = NSMenuItem()
        let known = sessions.filter(\.hasStatus)
        var parts: [String] = []
        let busy = known.filter { $0.status == "busy" }.count
        if busy > 0 { parts.append("\(busy) BUSY") }
        let idle = known.count - busy
        if idle > 0 { parts.append("\(idle) IDLE") }
        let unknown = sessions.count - known.count
        if unknown > 0 { parts.append("\(unknown) UNKNOWN") }
        header.attributedTitle = mono(
            "SESSIONS · " + (parts.isEmpty ? "0" : parts.joined(separator: "  ·  ")),
            size: 10, color: .secondaryLabelColor, bold: true)
        header.isEnabled = false
        menu.addItem(header)

        if sessions.isEmpty {
            let none = NSMenuItem()
            none.attributedTitle = mono("  no running sessions", size: 12, color: .secondaryLabelColor)
            none.isEnabled = false
            menu.addItem(none)
        }

        for s in sessions {
            let mi = NSMenuItem(title: "", action: #selector(revealSession(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = s.sessionId
            mi.attributedTitle = row(for: s)
            mi.isEnabled = s.ownerApp != nil
            menu.addItem(mi)

            // Option swaps the row for its details, since a row cannot both act
            // and open a submenu.
            let alt = NSMenuItem()
            alt.attributedTitle = row(for: s)
            alt.submenu = submenu(for: s)
            alt.isAlternate = true
            alt.keyEquivalentModifierMask = .option
            menu.addItem(alt)
        }

        let hint = NSMenuItem()
        hint.attributedTitle = mono("   click to reveal · ⌥ for details", size: 10, color: .tertiaryLabelColor)
        hint.isEnabled = false
        menu.addItem(hint)

        menu.addItem(.separator())

        let refreshItem = NSMenuItem(title: "Refresh now", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(alertsMenuItem())

        let follow = NSMenuItem(title: "Follow focused terminal", action: #selector(toggleFollow), keyEquivalent: "")
        follow.target = self
        follow.state = followFocus ? .on : .off
        menu.addItem(follow)

        let every = NSMenuItem(title: "Refresh every", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for minutes in [1, 3, 5, 10] {
            let it = NSMenuItem(title: "\(minutes) min", action: #selector(setInterval(_:)), keyEquivalent: "")
            it.target = self
            it.tag = minutes
            it.state = Int(interval) == minutes * 60 ? .on : .off
            sub.addItem(it)
        }
        every.submenu = sub
        menu.addItem(every)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func row(for s: Session) -> NSAttributedString {
        let line = NSMutableAttributedString()
        let busy = s.status == "busy"
        let isFocused = focusedSession?.sessionId == s.sessionId
        line.append(mono(isFocused ? "▸" : " ", size: 12, color: .secondaryLabelColor))
        if s.hasStatus {
            line.append(mono(busy ? "● " : "○ ", size: 12, color: busy ? .systemGreen : .tertiaryLabelColor))
        } else {
            // registered but silent about its state, or seen only through activity
            line.append(mono("◌ ", size: 12, color: .tertiaryLabelColor))
        }
        line.append(mono("\t" + pad(s.name, 22), size: 12, bold: true))
        line.append(mono("\t\(fmtTokens(s.contextTokens)) / \(fmtTokens(s.contextLimit))", size: 12, color: .secondaryLabelColor))
        line.append(mono(String(format: "\t%.0f%%", s.percent), size: 12, color: heatColor(s.percent), bold: true))
        line.append(mono("\t" + bar(s.percent), size: 12, color: heatColor(s.percent)))
        var subtitle = "\n     " + tildePath(s.cwd) + "  ·  " + s.modelName
        if s.entrypoint != "cli" { subtitle += "  ·  " + sourceLabel(s.entrypoint) }
        subtitle += "  ·  " + ago(s.updatedAt)
        line.append(mono(subtitle, size: 10, color: .secondaryLabelColor))
        line.addAttribute(.paragraphStyle, value: sessionColumns, range: NSRange(location: 0, length: line.length))
        return line
    }

    private func submenu(for s: Session) -> NSMenu {
        let m = NSMenu()

        for text in ["pid \(s.pid)  ·  \(s.tty.isEmpty ? "no tty" : s.tty)  ·  v\(s.version)",
                     "context \(s.contextTokens) tokens",
                     String(format: "cost $%.2f", s.costUSD),
                     "session \(s.sessionId)"] {
            let it = NSMenuItem()
            it.attributedTitle = mono(text, size: 11, color: .secondaryLabelColor)
            it.isEnabled = false
            m.addItem(it)
        }
        m.addItem(.separator())

        let copyId = NSMenuItem(title: "Copy session id", action: #selector(copyString(_:)), keyEquivalent: "")
        copyId.target = self
        copyId.representedObject = s.sessionId
        m.addItem(copyId)

        let copyResume = NSMenuItem(title: "Copy resume command", action: #selector(copyString(_:)), keyEquivalent: "")
        copyResume.target = self
        copyResume.representedObject = "claude --resume \(s.sessionId)"
        m.addItem(copyResume)

        if !s.cwd.isEmpty {
            let openCwd = NSMenuItem(title: "Open working directory", action: #selector(openPath(_:)), keyEquivalent: "")
            openCwd.target = self
            openCwd.representedObject = s.cwd
            m.addItem(openCwd)
        }
        if let t = s.transcript {
            let reveal = NSMenuItem(title: "Reveal transcript in Finder", action: #selector(revealPath(_:)), keyEquivalent: "")
            reveal.target = self
            reveal.representedObject = t.path
            m.addItem(reveal)
        }
        return m
    }

    // MARK: actions

    @objc private func revealSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let s = sessions.first(where: { $0.sessionId == id }) else { return }
        focusQueue.async {
            if let source = revealScript(bundleId: s.ownerBundleId, tty: s.tty),
               let script = NSAppleScript(source: source) {
                var err: NSDictionary?
                let result = script.executeAndReturnError(&err)
                if err == nil, result.stringValue == "ok" { return }
            }
            // no way to address the tab — raising the owning app is the best left
            guard let app = s.ownerApp else { return }
            DispatchQueue.main.async {
                NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
            }
        }
    }

    @objc private func refreshNow() { refresh() }

    private func alertsMenuItem() -> NSMenuItem {
        let levels = alertLevels.map { "\($0)" }.joined(separator: " / ")
        let item = NSMenuItem(title: "Alerts  (\(levels)%)", action: nil, keyEquivalent: "")
        let sub = NSMenu()

        let enabled = NSMenuItem(title: "Enabled", action: #selector(toggleFlag(_:)), keyEquivalent: "")
        enabled.target = self
        enabled.representedObject = "alertsEnabled"
        enabled.state = alertsEnabled ? .on : .off
        sub.addItem(enabled)
        sub.addItem(.separator())

        for (title, key, on) in [("Session context", "alertContext", alertContext),
                                 ("Weekly limit", "alertLimit", alertLimit)] {
            let it = NSMenuItem(title: title, action: #selector(toggleFlag(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = key
            it.state = on ? .on : .off
            it.isEnabled = alertsEnabled
            sub.addItem(it)
        }
        sub.addItem(.separator())

        let hookItem = NSMenuItem(title: "Also send to push script", action: #selector(toggleFlag(_:)), keyEquivalent: "")
        hookItem.target = self
        hookItem.representedObject = "usePushHook"
        hookItem.state = usePushHook ? .on : .off
        hookItem.isEnabled = alertsEnabled && notifyHook != nil
        sub.addItem(hookItem)

        let choose = NSMenuItem(title: "Push script…", action: #selector(editPushScript), keyEquivalent: "")
        choose.target = self
        sub.addItem(choose)

        let hookInfo = NSMenuItem()
        let custom = UserDefaults.standard.string(forKey: "notifyHook") ?? ""
        if let hook = notifyHook {
            hookInfo.attributedTitle = mono("   " + tildePath(hook.path), size: 10, color: .tertiaryLabelColor)
        } else if custom.isEmpty {
            hookInfo.attributedTitle = mono("   none set", size: 10, color: .tertiaryLabelColor)
        } else {
            hookInfo.attributedTitle = mono("   not executable: " + custom, size: 10, color: .systemOrange)
        }
        hookInfo.isEnabled = false
        sub.addItem(hookInfo)
        sub.addItem(.separator())

        let edit = NSMenuItem(title: "Change thresholds…", action: #selector(editThresholds), keyEquivalent: "")
        edit.target = self
        sub.addItem(edit)

        item.submenu = sub
        return item
    }

    @objc private func toggleFlag(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        let current = UserDefaults.standard.object(forKey: key) as? Bool ?? true
        UserDefaults.standard.set(!current, forKey: key)
        rebuild()
    }

    @objc private func editPushScript() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Push script"
        alert.informativeText = """
            An executable run for every alert. It gets the message as $1 and a             JSON object on stdin: kind, level, percent, message, at, plus the             session or the limit window it is about.

            Leave this empty to use ~/.claude/widget-notify when one exists.
            """
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.stringValue = UserDefaults.standard.string(forKey: "notifyHook") ?? ""
        field.placeholderString = "~/.claude/widget-notify"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let path = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty {
            UserDefaults.standard.removeObject(forKey: "notifyHook")
        } else {
            UserDefaults.standard.set(path, forKey: "notifyHook")
        }
        rebuild()
    }

    @objc private func editThresholds() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Alert thresholds"
        alert.informativeText = "Percentages to warn at, comma separated. Each level fires once per session until it drops back below the lowest one."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = alertLevels.map { "\($0)" }.joined(separator: ", ")
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let parsed = field.stringValue
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
            .filter { (1...100).contains($0) }
        let levels = Array(Set(parsed)).sorted()
        UserDefaults.standard.set(levels.isEmpty ? [80, 90, 95] : levels, forKey: "alertLevels")
        // thresholds moved, so nothing already sent should suppress the new ones
        UserDefaults.standard.removeObject(forKey: "alertState")
        rebuild()
    }

    @objc private func toggleFollow() {
        UserDefaults.standard.set(!followFocus, forKey: "followFocus")
        startFocusTimer()
        rebuild()
    }

    @objc private func setInterval(_ sender: NSMenuItem) {
        UserDefaults.standard.set(Double(sender.tag * 60), forKey: "refreshInterval")
        startTimer()
    }

    @objc private func copyString(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    @objc private func openPath(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? String else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: p))
    }

    @objc private func revealPath(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? String else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
    }
}

// MARK: - Entry

// `ClaudeContextMonitor --print` dumps the same data as text, for checking the
// collector without the menu bar.
if CommandLine.arguments.contains("--print") {
    let found = collect()
    if let l = loadLimits() {
        print("USAGE LIMITS")
        print("   5-hour  " + pad("\(l.fiveHourPct.map { "\($0)%" } ?? "-")", 6) + bar(Double(l.fiveHourPct ?? 0)) + "  resets in " + until(l.fiveHourResets))
        print("   7-day   " + pad("\(l.sevenDayPct.map { "\($0)%" } ?? "-")", 6) + bar(Double(l.sevenDayPct ?? 0)) + "  resets in " + until(l.sevenDayResets))
        print("")
    }
    print("SESSIONS · \(found.count)")
    for s in found {
        let marker = s.hasStatus ? (s.status == "busy" ? "●" : "○") : "◌"
        print("  " + marker + " " + pad(s.name, 24)
              + pad("\(fmtTokens(s.contextTokens)) / \(fmtTokens(s.contextLimit))", 16)
              + pad(String(format: "%.0f%%", s.percent), 6) + bar(s.percent))
        print("      " + (s.cwd.isEmpty ? "?" : tildePath(s.cwd)) + "  ·  " + s.modelName
              + "  ·  " + (s.entrypoint == "cli" ? "pid \(s.pid)" : sourceLabel(s.entrypoint))
              + "  ·  " + ago(s.updatedAt))
        print("      \(s.contextTokens) tokens  ·  \(s.sessionId)")
    }
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = Controller()
app.run()
