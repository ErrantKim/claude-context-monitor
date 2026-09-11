import Foundation

// Claude Code pipes a JSON blob to this on every status line render. It is the
// only passive source for account rate limits, so we stash what the menu bar
// app needs and print a compact line back.

let cacheDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude/widget-cache")

func writeAtomically(_ obj: [String: Any], to url: URL) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
    let tmp = url.appendingPathExtension("tmp-\(getpid())")
    guard (try? data.write(to: tmp)) != nil else { return }
    _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
    try? FileManager.default.removeItem(at: tmp)   // no-op when the replace consumed it
}

func pct(_ any: Any?) -> Int {
    if let i = any as? Int { return i }
    if let d = any as? Double { return Int(d.rounded()) }
    return 0
}

let input = FileHandle.standardInput.readDataToEndOfFile()
guard let root = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] else { exit(0) }

try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

let now = Int(Date().timeIntervalSince1970)
let sessionId = root["session_id"] as? String ?? "unknown"
let model = root["model"] as? [String: Any]
let modelName = model?["display_name"] as? String ?? "?"
let ctx = root["context_window"] as? [String: Any]
let ctxPct = pct(ctx?["used_percentage"])
let ctxSize = pct(ctx?["context_window_size"])
let cost = (root["cost"] as? [String: Any])?["total_cost_usd"] as? Double ?? 0

// Account-wide limits: every session reports the same numbers, so one file.
var fiveHour = -1, sevenDay = -1
if let rl = root["rate_limits"] as? [String: Any] {
    var out: [String: Any] = ["updated_at": now, "source_session": sessionId]
    if let f = rl["five_hour"] as? [String: Any] {
        fiveHour = pct(f["used_percentage"])
        out["five_hour_pct"] = fiveHour
        out["five_hour_resets_at"] = pct(f["resets_at"])
    }
    if let s = rl["seven_day"] as? [String: Any] {
        sevenDay = pct(s["used_percentage"])
        out["seven_day_pct"] = sevenDay
        out["seven_day_resets_at"] = pct(s["resets_at"])
    }
    if let sl = rl["spend_limit"] as? [String: Any] {
        out["spend_limit_pct"] = pct(sl["used_percentage"])
    }
    writeAtomically(out, to: cacheDir.appendingPathComponent("limits.json"))
}

// Per-session context, straight from Claude Code rather than guessed from the
// transcript tail.
var used = 0
if let cu = ctx?["current_usage"] as? [String: Any] {
    used = pct(cu["input_tokens"]) + pct(cu["cache_creation_input_tokens"])
         + pct(cu["cache_read_input_tokens"]) + pct(cu["output_tokens"])
}
let snapshot: [String: Any] = [
    "session_id": sessionId,
    "session_name": root["session_name"] as? String ?? "",
    "cwd": root["cwd"] as? String ?? "",
    "model": modelName,
    "model_id": model?["id"] as? String ?? "",
    "context_pct": ctxPct,
    "context_tokens": used,
    "context_size": ctxSize,
    "cost_usd": cost,
    "updated_at": now,
]
writeAtomically(snapshot, to: cacheDir.appendingPathComponent("session-\(sessionId).json"))

// Drop snapshots of sessions that ended long ago.
if let files = try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: [.contentModificationDateKey]) {
    let cutoff = Date().addingTimeInterval(-7 * 86400)
    for f in files where f.lastPathComponent.hasPrefix("session-") {
        if let d = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, d < cutoff {
            try? FileManager.default.removeItem(at: f)
        }
    }
}

// MARK: - the line shown in the terminal

// If the user already had a status line, the installer saved it here. Theirs is
// what gets displayed — collecting the cache must not cost anyone their setup.
let chainFile = cacheDir.appendingPathComponent("chain")
if let raw = try? String(contentsOf: chainFile, encoding: .utf8) {
    let command = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if !command.isEmpty {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        if (try? p.run()) != nil {
            stdin.fileHandleForWriting.write(input)
            try? stdin.fileHandleForWriting.close()
            let out = stdout.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            FileHandle.standardOutput.write(out)
            exit(0)
        }
    }
}

let dim = "\u{1b}[2m", reset = "\u{1b}[0m", sep = "\u{1b}[2m · \u{1b}[0m"
var parts = ["\(dim)\(modelName)\(reset)", "ctx \(ctxPct)%"]
if fiveHour >= 0 { parts.append("5h \(fiveHour)%") }
if sevenDay >= 0 { parts.append("7d \(sevenDay)%") }
parts.append(String(format: "\(dim)$%.2f\(reset)", cost))
print(parts.joined(separator: sep))
