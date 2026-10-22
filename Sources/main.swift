// Baa: a tiny ram for your RAM. menu bar monitor that finds leftovers (ghost processes, junk AI agents
// leave running, idle hogs), frees them in one click, and warns before you hit red.
import SwiftUI
import AppKit
import UserNotifications
import Darwin

// MARK: - readings

enum Mem {
    static func int32(_ name: String) -> Int {
        var v: Int32 = 0; var s = MemoryLayout<Int32>.size
        sysctlbyname(name, &v, &s, nil, 0); return Int(v)
    }
    static var freePct: Int { int32("kern.memorystatus_level") }          // what memory_pressure calls "free percentage"
    static var level: Int { int32("kern.memorystatus_vm_pressure_level") } // 1 normal, 2 warn, 4 critical
    static var swapGB: Double {
        var x = xsw_usage(); var s = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &x, &s, nil, 0); return Double(x.xsu_used) / 1_073_741_824
    }
}

@discardableResult
func run(_ path: String, _ args: [String]) -> (out: String, status: Int32) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return ("", -1) }
    let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return (String(decoding: d, as: UTF8.self), p.terminationStatus)
}

func dur(_ s: Double) -> String {
    let m = Int(s / 60); if m < 60 { return "\(m)m" }
    let h = m / 60; if h >= 48 { return "\(h / 24)d" }
    return (m % 60 == 0 || h >= 10) ? "\(h)h" : "\(h)h \(m % 60)m"
}
func size(_ b: Double) -> String {
    b >= 1_073_741_824 ? String(format: "%.1f GB", b / 1_073_741_824) : "\(Int(b / 1_048_576)) MB"
}

// MARK: - processes

struct Proc {
    let pid: Int, ppid: Int, uid: Int, rssKB: Int
    let elapsed: Double, cpu: Double, pcpu: Double
    let exe: String, cmd: String
    var label = ""
    var bytes = 0.0
    var base: String { (exe as NSString).lastPathComponent }
}

// same number activity monitor shows. unlike rss it includes memory macOS has compressed,
// which is exactly what idle leftovers turn into. only readable for your own processes
func footprint(_ pid: Int) -> Double? {
    var info = rusage_info_v4()
    let ok = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(Int32(pid), RUSAGE_INFO_V4, $0) }
    }
    return ok == 0 ? Double(info.ri_phys_footprint) : nil
}

// "[dd-][hh:]mm:ss[.cc]" -> seconds (works for both etime and cputime)
func secs(_ s: Substring) -> Double {
    var days = 0.0, rest = s
    if let d = s.firstIndex(of: "-") { days = Double(s[..<d]) ?? 0; rest = s[s.index(after: d)...] }
    return days * 86400 + rest.split(separator: ":").reduce(0.0) { $0 * 60 + (Double($1) ?? 0) }
}

// BAA_FAST=1 turns every "N minutes" threshold into N seconds (for testing)
let fast = ProcessInfo.processInfo.environment["BAA_FAST"] != nil
func mins(_ m: Double) -> Double { fast ? m : m * 60 }

let agentLabels: Set<String> = ["Claude Code", "Codex"]
let runtimeLabels: Set<String> = ["Node", "Python", "Bun", "Deno", "Ruby", "Java", "Headless browser", "Gradle", "Kotlin daemon"]
let shells: Set<String> = ["zsh", "-zsh", "bash", "-bash", "sh", "fish", "-fish", "login", "tmux", "screen"]

func isHeadless(_ exe: String, _ cmd: String) -> Bool {
    ["ms-playwright", "puppeteer", "chrome-headless-shell", "Chrome for Testing"].contains { exe.contains($0) }
        || (cmd.contains("--headless") && (exe.contains("Chrom") || exe.contains("chrom")))
}

// outermost .app in the path, so every "Google Chrome Helper" rolls up into "Google Chrome"
func appName(_ exe: String) -> String? {
    guard let r = exe.range(of: ".app/") else { return nil }
    return exe[..<r.lowerBound].split(separator: "/").last.map(String.init)
}

func label(_ exe: String, _ cmd: String) -> String {
    let base = (exe as NSString).lastPathComponent
    if cmd.contains("GradleDaemon") { return "Gradle" }
    if cmd.contains("KotlinCompileDaemon") || cmd.contains("kotlin-daemon") { return "Kotlin daemon" }
    if base.hasPrefix("qemu-system") || base == "emulator" { return "Android emulator" }
    if exe.contains("launchd_sim") || exe.contains("/CoreSimulator/Devices/") || exe.contains("Simulator.app/Contents/MacOS/Simulator") { return "iOS Simulator" }
    if isHeadless(exe, cmd) { return "Headless browser" }
    if base.lowercased().hasPrefix("python") { return "Python" }
    if base == "claude" || exe.contains("/claude/versions/") { return "Claude Code" }
    if base == "codex" { return "Codex" }
    if let a = appName(exe) { return a }
    switch base {
    case "node": return "Node"
    case "bun": return "Bun"
    case "deno": return "Deno"
    case "ruby": return "Ruby"
    case "java": return "Java"
    case "ollama": return "Ollama"
    default: return base
    }
}

func readProcs() -> [Int: Proc] {
    var exe: [Int: String] = [:]
    for line in run("/bin/ps", ["-axww", "-o", "pid=,comm="]).out.split(separator: "\n") {
        let t = line.drop(while: { $0 == " " })
        guard let sp = t.firstIndex(of: " "), let pid = Int(t[..<sp]) else { continue }
        exe[pid] = String(t[sp...].drop(while: { $0 == " " }))
    }
    var out: [Int: Proc] = [:]
    for line in run("/bin/ps", ["-axww", "-o", "pid=,ppid=,uid=,rss=,etime=,time=,%cpu=,command="]).out.split(separator: "\n") {
        let f = line.split(separator: " ", maxSplits: 7, omittingEmptySubsequences: true)
        guard f.count == 8, let pid = Int(f[0]), let ppid = Int(f[1]), let uid = Int(f[2]), let rss = Int(f[3]) else { continue }
        let e = exe[pid] ?? String(f[7])
        var p = Proc(pid: pid, ppid: ppid, uid: uid, rssKB: rss, elapsed: secs(f[4]), cpu: secs(f[5]),
                     pcpu: Double(f[6]) ?? 0, exe: e, cmd: String(f[7]))
        p.label = label(e, p.cmd)
        p.bytes = footprint(pid) ?? Double(rss) * 1024
        out[pid] = p
    }
    return out
}

// short name for what a node/python process is actually running
func hint(_ p: Proc) -> String? {
    let toks = p.cmd.split(separator: " ").map(String.init)
    for w in ["vite", "next", "webpack", "jupyter", "uvicorn", "streamlit", "gunicorn", "flask", "expo", "metro"]
    where toks.contains(where: { ($0 as NSString).lastPathComponent == w || ($0 as NSString).lastPathComponent.hasPrefix(w + "-") }) { return w }
    if let i = toks.firstIndex(of: "-m"), i + 1 < toks.count { return toks[i + 1] }
    if let s = toks.dropFirst().first(where: { t in [".py", ".js", ".mjs", ".cjs", ".ts"].contains { t.hasSuffix($0) } }) {
        return (s as NSString).lastPathComponent
    }
    return nil
}

// MARK: - findings

enum Kind { case ghost, agent, idle, hot }
enum Fix { case kill([Int]), quit(String), run(String, [String]) }

struct Finding: Identifiable {
    let id: String, kind: Kind, title: String, detail: String, bytes: Double, fix: Fix
    var freeLabel: String { kind == .hot ? "Stop" : "Free \(size(bytes))" }
}

struct Scan {
    var apps: [(name: String, gb: Double)] = []
    var findings: [Finding] = []
    var freeable: Double { findings.reduce(0) { $0 + $1.bytes } }
}

final class Engine {
    // per-pid cpu history, so "idle" means "hasn't used CPU lately", not just "low right now"
    private var seen: [Int: (cpu: Double, at: Date, active: Date, born: Date)] = [:]
    // when each pid started burning CPU (>= half a core), to catch runaways that never go idle
    private var hotSince: [Int: Date] = [:]
    private let me = Int(getuid())

    private func idle(_ p: Proc, _ now: Date) -> Double {
        let born = now.addingTimeInterval(-p.elapsed)
        if var s = seen[p.pid], abs(s.born.timeIntervalSince(born)) < 90 {
            let dt = now.timeIntervalSince(s.at)
            if dt > 0, (p.cpu - s.cpu) / dt >= 0.01 { s.active = now }
            s.cpu = p.cpu; s.at = now; seen[p.pid] = s
            return now.timeIntervalSince(s.active)
        }
        // first sighting: if it's barely touched the CPU in its whole life, call it idle since birth
        let quiet = p.elapsed > 0 && p.cpu / p.elapsed < 0.01
        let active = quiet ? born : now
        seen[p.pid] = (p.cpu, now, active, born)
        return now.timeIntervalSince(active)
    }

    private func launchdPIDs() -> Set<Int> {
        Set(run("/bin/launchctl", ["list"]).out.split(separator: "\n").compactMap { Int($0.split(separator: "\t").first ?? "") })
    }

    private func listeningPorts() -> [Int: [Int]] {
        var out: [Int: [Int]] = [:], cur = 0
        for l in run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-u", "\(me)", "-Fpn"]).out.split(separator: "\n") {
            if l.hasPrefix("p") { cur = Int(l.dropFirst()) ?? 0 }
            else if l.hasPrefix("n"), let c = l.lastIndex(of: ":"), let port = Int(l[l.index(after: c)...]),
                    !(out[cur]?.contains(port) ?? false) { out[cur, default: []].append(port) }
        }
        return out
    }

    private func cwds(_ pids: [Int]) -> [Int: String] {
        guard !pids.isEmpty else { return [:] }
        var out: [Int: String] = [:], cur = 0
        let args = ["-a", "-d", "cwd", "-p", pids.map(String.init).joined(separator: ","), "-Fpn"]
        for l in run("/usr/sbin/lsof", args).out.split(separator: "\n") {
            if l.hasPrefix("p") { cur = Int(l.dropFirst()) ?? 0 }
            else if l.hasPrefix("n") { out[cur] = (String(l.dropFirst()) as NSString).lastPathComponent }
        }
        return out
    }

    private func systemish(_ p: Proc) -> Bool {
        if runtimeLabels.contains(p.label) || agentLabels.contains(p.label) { return false }
        if !p.exe.hasPrefix("/") { return true } // bare names are almost always macOS agents
        let sys = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/", "/Library/Developer/",
                   "/Library/PrivilegedHelperTools/", "/Library/Application Support/", "/private/"]
        return sys.contains { p.exe.hasPrefix($0) } || [".app/", ".xpc/", ".framework/"].contains { p.exe.contains($0) }
    }

    func scan() -> Scan {
        let now = Date()
        let procs = readProcs()
        seen = seen.filter { procs[$0.key] != nil }
        hotSince = hotSince.filter { procs[$0.key] != nil }

        var kids: [Int: [Int]] = [:]
        for p in procs.values where p.pid != p.ppid { kids[p.ppid, default: []].append(p.pid) }
        func tree(_ pid: Int) -> [Int] {
            var out = [pid], i = 0
            while i < out.count { out += kids[out[i]] ?? []; i += 1 }
            return out
        }
        let mine = procs.values.filter { $0.uid == me }.sorted { $0.pid < $1.pid }
        var idleOf: [Int: Double] = [:], hotFor: [Int: Double] = [:]
        for p in mine {
            let first = seen[p.pid] == nil
            idleOf[p.pid] = idle(p, now)
            if p.pcpu >= 50 {
                // first sighting (eg `baa --now`): trust its lifetime average instead of waiting
                let since = hotSince[p.pid] ?? (first && p.cpu / max(p.elapsed, 1) >= 0.5 ? now.addingTimeInterval(-p.elapsed) : now)
                hotSince[p.pid] = since; hotFor[p.pid] = now.timeIntervalSince(since)
            } else { hotSince[p.pid] = nil }
        }
        func treeIdle(_ pids: [Int]) -> Double { pids.compactMap { idleOf[$0] }.min() ?? 0 }
        func treeBytes(_ pids: [Int]) -> Double { pids.compactMap { procs[$0]?.bytes }.reduce(0, +) }

        // never suggest killing whatever launched us (eg the terminal running `baa`)
        var claimed = Set<Int>([Int(getpid())])
        var a = Int(getppid())
        while let p = procs[a], a > 1 { claimed.insert(a); a = p.ppid }

        var found: [Finding] = []
        func add(_ id: String, _ kind: Kind, _ title: String, _ detail: String, _ pids: [Int], fix: Fix? = nil) {
            let pids = pids.filter { !claimed.contains($0) && procs[$0]?.uid == me }
            guard !pids.isEmpty, kind == .hot || treeBytes(pids) >= 50 * 1_048_576 else { return }
            claimed.formUnion(pids)
            found.append(Finding(id: id, kind: kind, title: title, detail: detail, bytes: treeBytes(pids), fix: fix ?? .kill(pids)))
        }

        let labels = Set(mine.map(\.label))
        let ideOpen = mine.contains {
            $0.label != "Gradle" && $0.label != "Kotlin daemon" &&
            ($0.exe.contains("Android Studio.app/Contents/MacOS/") || ($0.exe.contains("IntelliJ IDEA") && $0.exe.contains("/Contents/MacOS/")))
        }
        let simAppOpen = mine.contains { $0.exe.contains("Simulator.app/Contents/MacOS/Simulator") }

        // Gradle / Kotlin daemons outlive Android Studio by design
        let daemons = mine.filter { $0.label == "Gradle" || $0.label == "Kotlin daemon" }
        if !daemons.isEmpty {
            let pids = daemons.flatMap { tree($0.pid) }, i = treeIdle(pids)
            if !ideOpen && i >= mins(2) {
                add("gradle", .ghost, "Gradle + Kotlin daemons", "Android Studio is closed but these are still holding memory", pids)
            } else if i >= mins(20) {
                add("gradle", .idle, "Gradle + Kotlin daemons", "idle \(dur(i)) · they restart on your next build", pids)
            }
        }

        // simulators keep running after you close the Simulator window
        let sims = mine.filter { $0.exe.contains("launchd_sim") }
        if !sims.isEmpty && !simAppOpen {
            add("simulator", .ghost, "iOS Simulator (background)", "still booted, but the Simulator app is closed",
                sims.flatMap { tree($0.pid) }, fix: .run("/usr/bin/xcrun", ["simctl", "shutdown", "all"]))
        }

        // Android emulator
        let emu = mine.filter { $0.label == "Android emulator" && procs[$0.ppid]?.label != "Android emulator" }
        for e in emu {
            let pids = tree(e.pid), i = treeIdle(pids)
            if !ideOpen && i >= mins(10) { add("emulator", .ghost, "Android emulator", "Android Studio is closed · idle \(dur(i))", pids) }
            else if i >= mins(20) { add("emulator", .idle, "Android emulator", "no activity for \(dur(i))", pids) }
        }

        // Docker VM with nothing in it
        if let vm = mine.first(where: { ["com.docker.virtualization", "com.docker.hyperkit", "com.docker.krun"].contains(where: $0.cmd.contains) }) {
            let cli = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/Applications/Docker.app/Contents/Resources/bin/docker"]
                .first { FileManager.default.isExecutableFile(atPath: $0) }
            if let cli {
                let r = run(cli, ["ps", "-q"])
                if r.status == 0 && r.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    add("docker", .idle, "Docker", "VM is running with no containers", tree(vm.pid), fix: .quit("Docker"))
                }
            }
        }

        // Ollama keeps the last model in RAM
        for p in mine where p.label == "Ollama" && p.cmd.contains(" runner") {
            let pids = tree(p.pid), i = treeIdle(pids)
            if i >= mins(10) { add("ollama-\(p.pid)", .idle, "Ollama model", "still loaded, idle \(dur(i)) · reloads next time you use it", pids) }
        }

        // AI agents: what they leave running, then the sessions themselves
        let sessions = mine.filter { agentLabels.contains($0.label) && procs[$0.ppid]?.label != $0.label &&
                                     !$0.cmd.contains("--chrome-native-host") && !$0.cmd.contains(" mcp") }
        let cwd = cwds(sessions.map(\.pid))
        func agentRoot(_ p: Proc) -> Proc? {
            var a = p.ppid
            while let q = procs[a], a > 1 {
                if agentLabels.contains(q.label) || q.label == "Cursor" { return procs[a] }
                a = q.ppid
            }
            return nil
        }
        func who(_ r: Proc) -> String { r.label + (cwd[r.pid].map { " (\($0))" } ?? "") }
        let ports = listeningPorts()
        for p in mine where !claimed.contains(p.pid) {
            let headless = p.label == "Headless browser"
            guard headless || (["Node", "Python", "Bun", "Deno", "Ruby"].contains(p.label) && ports[p.pid] != nil) else { continue }
            if procs[p.ppid]?.label == p.label { continue } // only the top of a browser/server tree
            let root = agentRoot(p)
            guard root != nil || p.ppid == 1 else { continue }
            let pids = tree(p.pid), i = treeIdle(pids)
            guard i >= mins(15), p.elapsed >= mins(15) else { continue }
            let title = headless
                ? "Headless browser" + (p.exe.contains("playwright") ? " (Playwright)" : p.exe.contains("puppeteer") ? " (Puppeteer)" : "")
                : "Dev server" + (ports[p.pid]?.min().map { " :\($0)" } ?? "") + " · " + (hint(p) ?? p.label.lowercased())
            let by = root.map { "started by \(who($0))" } ?? "whatever started it is gone"
            add("agent-\(p.pid)", .agent, title, "\(by) · idle \(dur(i))", pids)
        }
        for s in sessions {
            let pids = tree(s.pid), i = treeIdle(pids)
            guard i >= mins(60) else { continue }
            let resume = s.label == "Codex" ? "codex resume" : "claude --resume"
            add("session-\(s.pid)", .idle, "\(s.label) session" + (cwd[s.pid].map { " · \($0)" } ?? ""),
                "idle \(dur(i)) · pick it back up later with \(resume)", pids)
        }

        // runaways: leftovers stuck burning CPU (fans + battery), which never look idle so the checks below miss them
        let launchd = launchdPIDs()
        for p in mine where (hotFor[p.pid] ?? 0) >= mins(5) && !claimed.contains(p.pid) && !shells.contains(p.base)
                            && !agentLabels.contains(p.label) && !systemish(p) {
            // climb to the top of the job (eg npm -> node -> esbuild), stopping at a shell, agent, app or launchd
            var top = p
            while let q = procs[top.ppid], q.pid > 1, q.uid == me, !shells.contains(q.base), !agentLabels.contains(q.label), !systemish(q) { top = q }
            let orphan = top.ppid == 1 && !launchd.contains(top.pid)
            let root = agentRoot(top), quiet = root.flatMap { idleOf[$0.pid] } ?? 0
            // a terminal you still have open is your call, and so is the agent you ran baa from
            guard orphan || (root != nil && !claimed.contains(root!.pid) && quiet >= mins(15)) else { continue }
            let pids = tree(top.pid), load = pids.compactMap { procs[$0]?.pcpu }.reduce(0, +)
            let by = orphan ? "its terminal or agent closed" : "started by \(who(root!)), idle \(dur(quiet))"
            add("hot-\(top.pid)", .hot, top.label + (hint(top).map { " · \($0)" } ?? ""),
                "\(Int(load.rounded()))% CPU for \(dur(hotFor[p.pid]!)) · \(by)", pids)
        }

        // orphans: reparented to launchd because the terminal / agent that started them closed
        for p in mine where p.ppid == 1 && !claimed.contains(p.pid) && !launchd.contains(p.pid) && !systemish(p) {
            if p.base.hasPrefix("tmux") || p.base.hasPrefix("screen") { continue }
            let pids = tree(p.pid).filter { !claimed.contains($0) }
            let b = treeBytes(pids), i = treeIdle(pids)
            guard b >= 150 * 1_048_576, i >= mins(10), p.elapsed >= mins(10),
                  let big = pids.compactMap({ procs[$0] }).max(by: { $0.bytes < $1.bytes }) else { continue }
            add("orphan-\(p.pid)", .ghost, big.label + (hint(big).map { " · \($0)" } ?? ""),
                "its terminal or agent closed · idle \(dur(i)), running \(dur(p.elapsed))", pids)
        }

        // anything else big that's been sitting idle
        for p in mine where !claimed.contains(p.pid) && !shells.contains(p.base) && !agentLabels.contains(p.label) && !systemish(p) {
            if let par = procs[p.ppid], par.label == p.label { continue }
            let pids = tree(p.pid).filter { !claimed.contains($0) }
            let b = treeBytes(pids), i = treeIdle(pids)
            guard b >= 500 * 1_048_576, i >= mins(30) else { continue }
            add("idle-\(p.pid)", .idle, p.label + (hint(p).map { " · \($0)" } ?? ""), "using \(size(b)), no activity for \(dur(i))", pids)
        }

        var g: [String: Double] = [:]
        for p in procs.values { g[p.label, default: 0] += p.bytes }
        let apps = g.map { (name: $0.key, gb: $0.value / 1_073_741_824) }.filter { $0.gb >= 0.2 }.sorted { $0.gb > $1.gb }
        _ = labels
        return Scan(apps: Array(apps.prefix(6)), findings: found.sorted { $0.bytes > $1.bytes })
    }
}

func apply(_ f: Finding, wait: Bool) {
    switch f.fix {
    case .kill(let pids):
        let ok = pids.filter { $0 > 1 && pid_t($0) != getpid() }
        for p in ok.reversed() { kill(pid_t(p), SIGTERM) }
        let finish = { for p in ok where kill(pid_t(p), 0) == 0 { kill(pid_t(p), SIGKILL) } }
        if wait { Thread.sleep(forTimeInterval: 4); finish() }
        else { DispatchQueue.global().asyncAfter(deadline: .now() + 4, execute: finish) }
    case .quit(let app): run("/usr/bin/osascript", ["-e", "quit app \"\(app)\""])
    case .run(let path, let args): run(path, args)
    }
}

func fixText(_ apps: [(name: String, gb: Double)]) -> String {
    let names = Set(apps.map(\.name))
    if names.contains("Xcode") && names.contains("Android Studio") { return "Xcode + Android Studio are both open → quit one" }
    if names.contains("Android emulator") { return "Emulator is running → close it, test on your phone" }
    if names.contains("iOS Simulator") { return "iOS Simulator is open → quit it if you're on your phone" }
    if let top = apps.first { return "\(top.name) is the biggest → close what you're done with" }
    return "close what you're done with"
}

// MARK: - disk

// only known, rebuildable dev junk. never your files, xcode archives, or emulator images
enum JunkAction { case trash([URL]), run([(String, [String])]) }

struct Junk: Identifiable {
    let id: String, icon: String, title: String, detail: String, bytes: Double, action: JunkAction
    var blockedBy: String? = nil
    var pingable = true   // cheap to rebuild, so the disk-full ping may offer it as a one-click clear
    var trashes: Bool { if case .trash = action { return true }; return false }
}

enum Disk {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static func h(_ p: String) -> URL { home.appendingPathComponent(p) }

    static var free: Double {
        let v = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Double(v?.volumeAvailableCapacityForImportantUsage ?? 0)
    }
    static var total: Double {
        let v = try? home.resourceValues(forKeys: [.volumeTotalCapacityKey])
        return Double(v?.volumeTotalCapacity ?? 0)
    }

    static func exists(_ u: URL) -> Bool { FileManager.default.fileExists(atPath: u.path) }

    static func du(_ urls: [URL]) -> Double {
        let paths = urls.map(\.path).filter { FileManager.default.fileExists(atPath: $0) }
        guard !paths.isEmpty else { return 0 }
        return run("/usr/bin/du", ["-sk"] + paths).out.split(separator: "\n")
            .compactMap { Double($0.split(separator: "\t").first ?? "") }.reduce(0, +) * 1024
    }

    static func modified(_ u: URL) -> Date {
        (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    static func children(_ u: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: [.contentModificationDateKey],
                                                      options: [.skipsHiddenFiles])) ?? []
    }

    // "2.3GB (45%)" -> bytes
    static func parseSize(_ s: Substring) -> Double {
        let t = s.split(separator: " ").first.map(String.init) ?? ""
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("B", 1)]
        for (u, m) in units where t.hasSuffix(u) { return (Double(t.dropLast(u.count)) ?? 0) * m }
        return 0
    }

    static func scan() -> [Junk] {
        var out: [Junk] = []
        let xcodeOpen = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dt.Xcode").isEmpty
        let quitXcode = xcodeOpen ? "quit Xcode first" : nil
        func add(_ id: String, _ icon: String, _ title: String, _ detail: String, _ urls: [URL], blocked: String? = nil) {
            let urls = urls.filter(exists)
            let b = du(urls)
            guard b >= 200 * 1_048_576 else { return }
            out.append(Junk(id: id, icon: icon, title: title, detail: detail, bytes: b, action: .trash(urls), blockedBy: blocked))
        }

        add("xcode-build", "🔨", "Xcode build files", "DerivedData · rebuilds on your next build",
            [h("Library/Developer/Xcode/DerivedData")], blocked: quitXcode)

        // device support: keep the newest version for each device model
        var old: [URL] = []
        for os in ["iOS", "watchOS", "tvOS", "visionOS"] {
            let byModel = Dictionary(grouping: children(h("Library/Developer/Xcode/\(os) DeviceSupport"))) {
                $0.lastPathComponent.split(separator: " ").first.map(String.init) ?? ""
            }
            for (_, dirs) in byModel { old += dirs.sorted { modified($0) > modified($1) }.dropFirst() }
        }
        add("device-support", "📲", "Old iOS device support", "versions your phone isn't on anymore · Xcode re-adds them if needed",
            old, blocked: quitXcode)

        // simulator runtimes: keep the newest per platform
        if let data = run("/usr/bin/xcrun", ["simctl", "runtime", "list", "-j"]).out.data(using: .utf8),
           let all = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            let rts = all.map { (id: $0.key, platform: $0.value["platformIdentifier"] as? String ?? "",
                                 version: $0.value["version"] as? String ?? "", size: ($0.value["sizeBytes"] as? NSNumber)?.doubleValue ?? 0) }
            var stale: [(id: String, platform: String, version: String, size: Double)] = []
            for (_, group) in Dictionary(grouping: rts, by: { $0.platform }) {
                stale += group.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }.dropFirst()
            }
            let bytes = stale.reduce(0) { $0 + $1.size }
            if bytes >= 200 * 1_048_576 {
                out.append(Junk(id: "sim-runtimes", icon: "📱", title: "Old simulator versions",
                                detail: stale.map { "iOS \($0.version)" }.sorted().joined(separator: ", ") + " · keeps your newest one",
                                bytes: bytes, action: .run(stale.map { ("/usr/bin/xcrun", ["simctl", "runtime", "delete", $0.id]) }),
                                blockedBy: quitXcode))
            }
        }
        add("sim-caches", "📱", "Simulator caches", "rebuild automatically", [h("Library/Developer/CoreSimulator/Caches")])

        add("gradle", "🐘", "Gradle caches", "re-download on your next Android build",
            [h(".gradle/caches"), h(".gradle/daemon"), h(".gradle/wrapper/dists")])
        add("js", "📦", "npm / yarn / bun caches", "re-download next time you install",
            [h(".npm/_cacache"), h("Library/Caches/Yarn"), h(".bun/install/cache")])
        add("python", "🐍", "pip / uv caches", "re-download next time you install", [h("Library/Caches/pip"), h(".cache/uv")])
        add("brew", "🍺", "Homebrew / CocoaPods / SwiftPM caches", "old downloads",
            [h("Library/Caches/Homebrew"), h("Library/Caches/CocoaPods"), h("Library/Caches/org.swift.swiftpm")])
        add("test-browsers", "🧪", "Test browsers (Playwright / Puppeteer)", "reinstall with npx playwright install",
            [h("Library/Caches/ms-playwright"), h(".cache/puppeteer")])
        // models: only ones you haven't opened in 2 weeks. if one comes back after a clean, an app needs it, so leave it alone
        let cleaned = Set(UserDefaults.standard.stringArray(forKey: "cleanedModels") ?? [])
        let models = children(h(".cache/huggingface/hub")).filter { m in
            m.lastPathComponent.hasPrefix("models--") && !cleaned.contains(m.lastPathComponent) &&
            run("/usr/bin/find", [m.path, "-type", "f", "-atime", "-14", "-print", "-quit"]).out.isEmpty
        }
        let before = out.count
        add("hf", "🤗", "Unused Hugging Face models",
            "\(models.count) not opened in 2+ weeks · " + models.prefix(2).map { $0.lastPathComponent.components(separatedBy: "--").last ?? "" }.joined(separator: ", "),
            models)
        if out.count > before { out[out.count - 1].pingable = false }

        // installers sitting in Downloads for over a week
        let weekAgo = Date().addingTimeInterval(-7 * 86400)
        let installers = children(h("Downloads")).filter { ["dmg", "pkg", "iso"].contains($0.pathExtension.lowercased()) && modified($0) < weekAgo }
        add("installers", "💿", "Old installers in Downloads", "\(installers.count) .dmg / .pkg files, older than a week", installers)

        // node_modules in projects nobody has touched in a month
        let monthAgo = Date().addingTimeInterval(-30 * 86400)
        let found = run("/usr/bin/find", [home.path, "-maxdepth", "5", "(", "-path", h("Library").path, "-o", "-name", ".*", ")", "-prune",
                                         "-o", "-type", "d", "-name", "node_modules", "-print", "-prune"]).out
        let stale = found.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }.filter { nm in
            let project = nm.deletingLastPathComponent()
            let last = ([project] + children(project).filter { $0.lastPathComponent != "node_modules" }).map(modified).max() ?? .distantPast
            return last < monthAgo
        }
        add("node-modules", "📦", "Old node_modules", "\(stale.count) projects untouched for 30+ days · npm install brings them back", stale)

        // docker: whatever it says is reclaimable
        if let cli = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/Applications/Docker.app/Contents/Resources/bin/docker"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            let r = run(cli, ["system", "df", "--format", "{{.Reclaimable}}"])
            let bytes = r.status == 0 ? r.out.split(separator: "\n").map(parseSize).reduce(0, +) : 0
            if bytes >= 200 * 1_048_576 {
                out.append(Junk(id: "docker", icon: "🐳", title: "Docker leftovers", detail: "stopped containers, unused images, build cache",
                                bytes: bytes, action: .run([(cli, ["system", "prune", "-f"])])))
            }
        }
        return out.sorted { $0.bytes > $1.bytes }
    }

    // biggest folders in your home (Library and hidden folders split out), for when the junk list can't explain a full disk
    static func space() -> [(url: URL, bytes: Double)] {
        let skip: Set<String> = ["Library", ".Trash"]
        var dirs = children(home).filter { !skip.contains($0.lastPathComponent) }
        dirs += ((try? FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != ".Trash" }
        dirs += children(h("Library")) + [h(".Trash")]
        var out: [(URL, Double)] = []
        for l in run("/usr/bin/du", ["-skx"] + dirs.map(\.path)).out.split(separator: "\n") {
            let f = l.split(separator: "\t", maxSplits: 1)
            guard f.count == 2, let kb = Double(f[0]), kb * 1024 >= 1e9 else { continue }
            out.append((URL(fileURLWithPath: String(f[1])), kb * 1024))
        }
        return out.sorted { $0.1 > $1.1 }.map { (url: $0.0, bytes: $0.1) }
    }

    static func clean(_ j: Junk) {
        switch j.action {
        case .trash(let urls):
            for u in urls { try? FileManager.default.trashItem(at: u, resultingItemURL: nil) }
            if j.id == "hf" {
                let names = (UserDefaults.standard.stringArray(forKey: "cleanedModels") ?? []) + urls.map(\.lastPathComponent)
                UserDefaults.standard.set(Array(Set(names)), forKey: "cleanedModels")
            }
        case .run(let cmds): for (path, args) in cmds { run(path, args) }
        }
    }
}

// MARK: - ask AI (opt-in)

// what's safe to delete among the big folders rules can't judge. goes through the user's own claude / pi CLI,
// so there's no key to set up. only folder names + sizes are sent, never file contents, and it never deletes anything
struct Verdict: Identifiable {
    let id = UUID()
    let url: URL, bytes: Double, kind: String, why: String, name: String
    var chip: String { ["safe": "🟢 safe to delete", "app": "🟡 an app needs it", "yours": "🔵 your files"][kind] ?? "⚪ not sure" }
}

struct AIError: Error { let msg: String }

enum AI {
    static func cli() -> (name: String, path: String, args: [String])? {
        let home = Disk.home.path
        let options: [(String, [String], [String])] = [
            ("Claude", [home + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", home + "/.claude/local/claude"],
             ["-p", "--tools", "", "--model", "sonnet"]),
            ("pi", ["/opt/homebrew/bin/pi", "/usr/local/bin/pi", home + "/.local/bin/pi"], ["-p", "--no-session", "--no-tools"]),
        ]
        for (name, paths, args) in options {
            if let p = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return (name, p, args) }
        }
        return nil
    }

    // the big folders, plus what's inside the ones that aren't obviously yours (Library, hidden folders, Trash).
    // your own folders (Desktop, Documents, projects) are sent by name only, never what's in them
    static func folders(_ space: [(url: URL, bytes: Double)]) -> [String: Double] {
        var out: [String: Double] = [:]
        let home = Disk.home.path
        for d in space.prefix(10) {
            out[d.url.path] = d.bytes
            let rel = d.url.path.replacingOccurrences(of: home + "/", with: "")
            guard rel.hasPrefix("Library/") || rel.hasPrefix(".") else { continue }
            for l in run("/usr/bin/du", ["-kx", "-d", "2", d.url.path]).out.split(separator: "\n") {
                let f = l.split(separator: "\t", maxSplits: 1)
                guard f.count == 2, let kb = Double(f[0]), kb * 1024 >= 1e9 else { continue }
                out[String(f[1])] = kb * 1024
            }
        }
        return out
    }

    static func ask(_ space: [(url: URL, bytes: Double)]) -> Result<[Verdict], AIError> {
        guard let c = cli() else { return .failure(AIError(msg: "no claude or pi CLI found")) }
        let home = Disk.home.path, sizes = folders(space)
        let lines = sizes.sorted { $0.value > $1.value }.map { "\(size($0.value))\t" + $0.key.replacingOccurrences(of: home, with: "~") }
        let prompt = """
        Someone wants to free disk space on their Mac. These are the biggest folders in their home (size, path). \
        For the most useful paths, say whether deleting it is safe. Reply with ONLY a JSON array, no other text: \
        [{"path": "~/...", "name": "2-4 plain words, eg Spotify cache", "verdict": "safe" | "app" | "yours" | "unsure", "why": "under 12 words"}]. \
        safe = caches, build output, logs or old downloads that regenerate or aren't needed. \
        app = an installed app needs it (its models, data, settings), so deleting breaks it or it downloads again. \
        yours = the person's own files or projects. unsure = can't tell. \
        Prefer the most specific path, skip a parent if you judged its children. At most 10 items, biggest first.

        \(lines.joined(separator: "\n"))
        """
        let p = Process(); p.executableURL = URL(fileURLWithPath: c.path); p.arguments = c.args + [prompt]
        p.currentDirectoryURL = FileManager.default.temporaryDirectory
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(home)/.local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        p.environment = env
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return .failure(AIError(msg: "couldn't start \(c.name)")) }
        let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 150, execute: timer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); timer.cancel()
        let text = String(decoding: data, as: UTF8.self)
        guard let a = text.firstIndex(of: "["), let b = text.lastIndex(of: "]"), a < b,
              let items = try? JSONSerialization.jsonObject(with: Data(text[a...b].utf8)) as? [[String: String]] else {
            return .failure(AIError(msg: "\(c.name) didn't answer in time, try again"))
        }
        return .success(items.compactMap { (i: [String: String]) -> Verdict? in
            guard let path = i["path"] else { return nil }
            let full = path.hasPrefix("~") ? home + path.dropFirst() : path
            return Verdict(url: URL(fileURLWithPath: full), bytes: sizes[full] ?? 0, kind: i["verdict"] ?? "unsure", why: i["why"] ?? "",
                           name: i["name"] ?? (full.components(separatedBy: "/").last ?? ""))
        })
    }
}

// MARK: - health

enum Health {
    case ok, falling, tight, critical
    var word: String { ["healthy", "dropping fast", "getting tight", "critical"][index] }
    var dot: String { ["🟢", "🟠", "🟡", "🔴"][index] }
    var color: Color { [Color.green, .orange, .yellow, .red][index] }
    var ansi: String { ["\u{1B}[32m", "\u{1B}[38;5;208m", "\u{1B}[33m", "\u{1B}[31m"][index] }
    private var index: Int { switch self { case .ok: 0; case .falling: 1; case .tight: 2; case .critical: 3 } }

    static func of(free: Int, level: Int, minutesToRed: Double?) -> Health {
        if level >= 4 || free <= Limits.crit { return .critical }
        if free <= Limits.warn { return .tight }   // yellow is only ever your number
        if let m = minutesToRed, m <= 5 { return .falling }
        return .ok
    }
}

// when to go yellow / red, in % free. set from the panel or `baa warn <yellow> [red]`
enum Limits {
    static var warn: Int { get { read("warnAt", 15) } set { UserDefaults.standard.set(newValue, forKey: "warnAt") } }
    static var crit: Int { get { min(read("critAt", 8), warn - 1) } set { UserDefaults.standard.set(newValue, forKey: "critAt") } }
    static var trend: Bool {
        get { UserDefaults.standard.object(forKey: "trendAlerts") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "trendAlerts") }
    }
    private static func read(_ k: String, _ d: Int) -> Int { UserDefaults.standard.object(forKey: k) as? Int ?? d }
}

// MARK: - notifications

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private var handlers: [String: () -> Void] = [:]
    private var categories: [UNNotificationCategory] = []
    private var allowed = false

    func setup() {
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        c.requestAuthorization(options: [.alert, .sound]) { ok, _ in self.allowed = ok }
    }

    func post(_ title: String, _ subtitle: String, _ body: String, button: String? = nil, action: (() -> Void)? = nil) {
        guard allowed else {
            // no permission: plain notification, no button
            let esc = { (s: String) in s.replacingOccurrences(of: "\"", with: "'") }
            run("/usr/bin/osascript", ["-e", "display notification \"\(esc(body))\" with title \"\(esc(title))\" subtitle \"\(esc(subtitle))\" sound name \"Submarine\""])
            return
        }
        let c = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = title; content.subtitle = subtitle; content.body = body; content.sound = .default
        if let button, let action {
            // action titles are fixed per category, so each "Free 2.1 GB" button gets its own category
            let id = UUID().uuidString
            categories = Array((categories + [UNNotificationCategory(identifier: id, actions: [UNNotificationAction(identifier: "free", title: button)],
                                                                    intentIdentifiers: [])]).suffix(8))
            c.setNotificationCategories(Set(categories))
            content.categoryIdentifier = id
            handlers[id] = action
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            c.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse, withCompletionHandler done: @escaping () -> Void) {
        if r.actionIdentifier == "free", let h = handlers[r.notification.request.content.categoryIdentifier] { DispatchQueue.main.async(execute: h) }
        done()
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }
}

// MARK: - model

final class Model: ObservableObject {
    static let shared = Model()
    @Published var free = 100
    @Published var level = 1
    @Published var swap = 0.0
    @Published var scan = Scan()
    @Published var perMin = 0.0
    @Published var minutesToRed: Double?
    @Published var toast: String?
    @Published var busy: Set<String> = []
    @Published var spark: [Int] = []          // free %, every 10s, last 30 min
    @Published var shears = 0                 // bumps on every free, drives the wool burst
    @Published var fresh = false              // just sheared: skinny sheep for a moment
    var filmWool: Double?, filmBurst: Double? // baa film: drive the sheep frame by frame
    @Published var freedToday = 0.0
    @Published var freedAll = UserDefaults.standard.double(forKey: "freedAll")
    @Published var warnAt = Limits.warn { didSet { Limits.warn = warnAt; if critAt >= warnAt { critAt = warnAt - 1 } } }
    @Published var critAt = Limits.crit { didSet { Limits.crit = critAt } }
    @Published var trendOn = Limits.trend { didSet { Limits.trend = trendOn; if !trendOn { minutesToRed = nil } } }
    @Published var muted = UserDefaults.standard.bool(forKey: "muted") {
        didSet { UserDefaults.standard.set(muted, forKey: "muted") }
    }
    private var bleat: NSSound?

    // the little baa when Free actually frees something
    func baa() {
        guard !muted, let url = Bundle.main.url(forResource: "baa", withExtension: "wav") else { return }
        bleat = NSSound(contentsOf: url, byReference: true)
        bleat?.play()
    }

    var health: Health { .of(free: free, level: level, minutesToRed: minutesToRed) }

    // 0 = skinny sheep, 1 = giant fluffy cloud about to freeze your mac
    var wool: Double { filmWool ?? (fresh ? 0 : Model.woolFor(free)) }
    static func woolFor(_ free: Int) -> Double { min(1, max(0, Double(70 - free) / 60)) }

    // baa + shear + keep score
    private func sheared(_ bytes: Double) {
        baa()
        shears += 1; fresh = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { self.fresh = false }
        let d = UserDefaults.standard, day = Date().formatted(date: .numeric, time: .omitted)
        if d.string(forKey: "freedDay") != day { d.set(day, forKey: "freedDay"); d.set(0.0, forKey: "freedToday") }
        freedToday = d.double(forKey: "freedToday") + bytes; d.set(freedToday, forKey: "freedToday")
        freedAll += bytes; d.set(freedAll, forKey: "freedAll")
    }

    private func loadToday() {
        let d = UserDefaults.standard
        freedToday = d.string(forKey: "freedDay") == Date().formatted(date: .numeric, time: .omitted) ? d.double(forKey: "freedToday") : 0
    }
    private let engine = Engine()
    private let q = DispatchQueue(label: "baa.scan")
    private var history: [(at: Date, free: Int)] = []
    private var lastPing: (at: Date, critical: Bool)?
    private var trendPing: Date?
    // remembered across restarts so a relaunch doesn't re-ping the same leftover
    private var ghostPings: [String: Date] = ((UserDefaults.standard.dictionary(forKey: "ghostPings") as? [String: Double]) ?? [:])
        .mapValues { Date(timeIntervalSince1970: $0) }
    @Published var junk: [Junk] = []
    @Published var space: [(url: URL, bytes: Double)]? = nil
    @Published var measuring = false
    @Published var verdicts: [Verdict]? = nil
    @Published var asking = false
    @Published var aiError: String? = nil
    @Published var diskFree = 0.0
    var diskTotal = 0.0
    private var lastDiskScan: Date?
    private var diskPing: Date?
    private let dq = DispatchQueue(label: "baa.disk")

    func start() {
        Notifier.shared.setup()
        loadToday()
        DistributedNotificationCenter.default().addObserver(forName: .init("com.selvi.baa.test"), object: nil, queue: .main) { _ in self.test() }
        tick(); rescan()
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in self.tick() }
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in self.rescan() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { self.diskScan() }
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in self.diskScan() }
    }

    private func tick() {
        free = Mem.freePct; level = Mem.level; swap = Mem.swapGB
        let now = Date()
        history.append((now, free))
        spark.append(free); if spark.count > 180 { spark.removeFirst(spark.count - 180) }
        history.removeAll { now.timeIntervalSince($0.at) > 180 }
        trend()
        pressurePing()
    }

    // least-squares slope, in % free per minute
    static func slope(_ pts: ArraySlice<(at: Date, free: Int)>) -> Double {
        guard let t0 = pts.first?.at else { return 0 }
        let xs = pts.map { $0.at.timeIntervalSince(t0) / 60 }, ys = pts.map { Double($0.free) }
        let n = Double(xs.count), mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        let den = zip(xs, xs).map { ($0 - mx) * ($1 - mx) }.reduce(0, +)
        return den > 0 ? zip(xs, ys).map { ($0 - mx) * ($1 - my) }.reduce(0, +) / den : 0
    }

    // "dropping fast" only when it's a real slide, not one app launch that already leveled off:
    // falling over the last 3 min AND still falling in the last minute, and already within 10 points of yellow
    private func trend() { (perMin, minutesToRed) = Model.trend(history, free: free, warn: Limits.warn, on: Limits.trend) }

    static func trend(_ h: [(at: Date, free: Int)], free: Int, warn: Int, on: Bool) -> (Double, Double?) {
        guard h.count >= 8 else { return (0, nil) }
        let per = slope(h[...]), recent = slope(h.suffix(6)), gap = free - warn
        return (per, (on && per < -1.5 && recent < -1.5 && gap > 0 && gap <= 10) ? Double(gap) / -per : nil)
    }

    func rescan(then: (() -> Void)? = nil) {
        q.async {
            let s = self.engine.scan()
            DispatchQueue.main.async { self.scan = s; self.ghostPing(); then?() }
        }
    }

    private var subtitle: String {
        scan.apps.prefix(3).map { "\($0.name) \(String(format: "%.1f", $0.gb)) GB" }.joined(separator: "  ·  ")
    }

    private func pingWithBestFix(_ title: String) {
        if let f = scan.findings.first {
            Notifier.shared.post(title, subtitle, "\(f.title): \(f.detail)", button: f.freeLabel) { self.free(f.id) }
        } else {
            Notifier.shared.post(title, subtitle, fixText(scan.apps))
        }
    }

    private func pressurePing() {
        let now = Date(), h = health
        if h == .tight || h == .critical {
            // one ping per 30 min, unless it just got worse (yellow -> red)
            if let l = lastPing, h != .critical || l.critical, now.timeIntervalSince(l.at) < 1800 { return }
            lastPing = (now, h == .critical)
            pingWithBestFix("\(h.dot) RAM \(h.word) · \(free)% free")
        } else {
            lastPing = nil
            if h == .falling, let m = minutesToRed, trendPing.map({ now.timeIntervalSince($0) > 1800 }) ?? true {
                trendPing = now
                pingWithBestFix("🟠 RAM dropping fast · red in ~\(max(1, Int(m.rounded()))) min")
            }
        }
    }

    // big leftovers get one heads-up every 6h, even when RAM is fine
    private func ghostPing() {
        let now = Date()
        guard let f = scan.findings.first(where: { ($0.kind == .hot || ($0.kind != .idle && $0.bytes >= 1_073_741_824)) &&
                                                   ghostPings[$0.id].map { now.timeIntervalSince($0) > 6 * 3600 } ?? true }) else { return }
        ghostPings[f.id] = now
        UserDefaults.standard.set(ghostPings.mapValues(\.timeIntervalSince1970), forKey: "ghostPings")
        Notifier.shared.post(f.kind == .hot ? "🔥 stuck burning CPU" : "👻 \(size(f.bytes)) still running", f.title, f.detail, button: f.freeLabel) { self.free(f.id) }
    }

    private func test() {
        let h = health
        rescan { self.pingWithBestFix("\(h.dot) RAM \(h.word) · \(self.free)% free") }
    }

    func free(_ id: String) {
        busy.insert(id)
        q.async {
            guard let f = self.engine.scan().findings.first(where: { $0.id == id }) else {
                DispatchQueue.main.async { self.busy.remove(id); self.rescan() }
                return
            }
            apply(f, wait: true)
            DispatchQueue.main.async {
                self.busy.remove(id)
                self.sheared(f.bytes)
                self.flash("Freed \(size(f.bytes)) · \(f.title)")
                self.tick(); self.rescan()
            }
        }
    }

    func freeAll() {
        let ids = scan.findings.map(\.id), total = scan.freeable
        busy.formUnion(ids)
        q.async {
            let fs = self.engine.scan().findings.filter { ids.contains($0.id) }
            fs.forEach { apply($0, wait: false) }
            Thread.sleep(forTimeInterval: 4.5)
            DispatchQueue.main.async {
                self.busy.subtract(ids)
                if !ids.isEmpty { self.sheared(total) }
                self.flash("Freed \(size(total))")
                self.tick(); self.rescan()
            }
        }
    }

    // disk junk: scanned in the background every 6h (and when you open the menu, if stale)
    func diskScan(ifOlderThan age: TimeInterval = 0) {
        if let l = lastDiskScan, Date().timeIntervalSince(l) < age { return }
        lastDiskScan = Date()
        dq.async {
            let j = Disk.scan(), free = Disk.free, total = Disk.total
            DispatchQueue.main.async {
                self.junk = j; self.diskFree = free; self.diskTotal = total
                self.diskLowPing()
            }
        }
    }

    // under 10% or 15 GB free -> one ping every 12h, with the biggest safe cleanup on it
    private func diskLowPing() {
        let now = Date()
        guard diskTotal > 0, diskFree < max(diskTotal * 0.1, 15e9),
              diskPing.map({ now.timeIntervalSince($0) > 12 * 3600 }) ?? true else { return }
        diskPing = now
        let title = "💾 Disk almost full · \(size(diskFree)) left"
        if let j = junk.first(where: { $0.blockedBy == nil && $0.pingable }) {
            Notifier.shared.post(title, "\(size(junk.reduce(0) { $0 + $1.bytes })) of dev junk you can clear", "\(j.title): \(j.detail)",
                                 button: "Clear \(size(j.bytes))") { self.clean(j.id) }
        } else {
            Notifier.shared.post(title, "", "open baa to see what you can clear")
        }
    }

    func measureSpace() {
        measuring = true
        dq.async {
            let s = Disk.space()
            DispatchQueue.main.async {
                self.space = s; self.measuring = false
                if AI.cli() != nil && !s.isEmpty { self.askAI() }
            }
        }
    }

    func askAI() {
        guard let s = space else { return }
        asking = true; aiError = nil
        dq.async {
            let r = AI.ask(s)
            DispatchQueue.main.async {
                self.asking = false
                switch r { case .success(let v): self.verdicts = v; case .failure(let e): self.aiError = e.msg }
            }
        }
    }

    func clean(_ id: String) {
        busy.insert(id)
        dq.async {
            guard let j = Disk.scan().first(where: { $0.id == id }), j.blockedBy == nil else {
                DispatchQueue.main.async { self.busy.remove(id); self.diskScan() }
                return
            }
            Disk.clean(j)
            DispatchQueue.main.async {
                self.busy.remove(id)
                self.sheared(j.bytes)
                self.flash(j.trashes ? "Moved \(size(j.bytes)) to the Trash · empty it to get the space back"
                                     : "Cleared \(size(j.bytes)) · \(j.title)")
                self.diskScan()
            }
        }
    }

    private func flash(_ s: String) {
        toast = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { if self.toast == s { self.toast = nil } }
    }
}

// MARK: - sheep

// one drawing for both the menu bar (template silhouette) and the panel (colored)
func drawSheep(_ c: inout GraphicsContext, _ sz: CGSize, wool w: Double, template: Bool, woolColor: Color = .white, ink: Color = .black) {
    let k = min(sz.width / 100, sz.height / 80)
    c.translateBy(x: (sz.width - 100 * k) / 2, y: (sz.height - 80 * k) / 2)
    c.scaleBy(x: k, y: k)
    let face = template ? Color.black : ink
    let cx = 58.0, cy = 40.0, rx = 18 + 11 * w, ry = 12 + 6 * w, pr = 6 + 4 * w

    // legs
    for x in [cx - rx * 0.6, cx - rx * 0.25, cx + rx * 0.25, cx + rx * 0.6] {
        c.fill(Path(roundedRect: CGRect(x: x - 2.6, y: cy + ry - 4, width: 5.2, height: 78 - cy - ry), cornerRadius: 2.6), with: .color(face))
    }
    // wool: a ring of puffs around an ellipse
    var cloud = Path(ellipseIn: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
    for i in 0..<14 {
        let t = Double(i) / 14 * 2 * .pi
        let px = cx + cos(t) * rx, py = cy + sin(t) * ry
        cloud.addEllipse(in: CGRect(x: px - pr, y: py - pr, width: pr * 2, height: pr * 2))
    }
    if template {
        c.fill(cloud, with: .color(.black))
    } else {
        c.fill(cloud, with: .color(woolColor))
        c.stroke(cloud, with: .color(ink.opacity(0.18)), lineWidth: 1.2)
        c.fill(Path(ellipseIn: CGRect(x: cx - rx + 1, y: cy - ry + 1, width: rx * 2 - 2, height: ry * 2 - 2)), with: .color(woolColor))
    }
    // head, sticking out the front of the wool
    let hx = cx - rx - pr * 0.55, hy = cy - 4
    let head = Path(ellipseIn: CGRect(x: hx - 9, y: hy - 11, width: 18, height: 22))
    let ear = Path(ellipseIn: CGRect(x: hx + 4, y: hy - 9, width: 11, height: 6))
    if template {
        // cut a gap so the head reads as separate from the cloud
        c.blendMode = .clear
        c.stroke(head, with: .color(.black), lineWidth: 5)
        c.blendMode = .normal
    }
    c.fill(ear, with: .color(face)); c.fill(head, with: .color(face))
    // eye
    if template { c.blendMode = .clear }
    c.fill(Path(ellipseIn: CGRect(x: hx - 5.5, y: hy - 4, width: 4, height: 4)), with: .color(template ? .black : .white))
    c.blendMode = .normal
}

struct Sheep: View, Animatable {
    var wool: Double
    var animatableData: Double { get { wool } set { wool = newValue } }
    var color: Color = .white
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        // black face disappears on a dark panel, so it goes slate in dark mode
        Canvas { c, sz in drawSheep(&c, sz, wool: wool, template: false, woolColor: color, ink: Color(white: scheme == .dark ? 0.5 : 0.22)) }
    }
}

// wool puffs that fly off when you shear
struct Burst: View {
    let trigger: Int
    @State private var t = 0.0
    var p: Double { Model.shared.filmBurst ?? t }
    var body: some View {
        ZStack {
            ForEach(0..<9, id: \.self) { i in
                let a = Double(i) / 9 * 2 * .pi + 0.3
                Circle().fill(.white).overlay(Circle().stroke(Color.primary.opacity(0.15)))
                    .frame(width: 9 + Double(i % 3) * 3, height: 9 + Double(i % 3) * 3)
                    .offset(x: cos(a) * 54 * p, y: sin(a) * 40 * p - 18 * p * p)
                    .opacity(p == 0 ? 0 : 1 - p)
            }
        }
        .allowsHitTesting(false)
        .onChange(of: trigger) {
            t = 0.001
            DispatchQueue.main.async { withAnimation(.easeOut(duration: 1.1)) { t = 1 } }
        }
    }
}

// last 30 min of RAM use, with a dotted line toward red when it's falling
struct Spark: View {
    let free: [Int], perMin: Double, minutesToRed: Double?, color: Color
    var body: some View {
        Canvas { c, sz in
            let used = free.map { Double(100 - $0) }
            guard used.count > 1 else { return }
            let lo = max(0, (used.min() ?? 0) - 10), hi = 100.0
            let span = Double(max(used.count, 30)), ahead = minutesToRed.map { min(60, $0 * 6) } ?? 0   // samples are 10s apart
            let w = sz.width, h = sz.height
            let x = { (i: Double) in w * i / (span + ahead) }
            let y = { (v: Double) in h - h * (v - lo) / (hi - lo) }
            let start = span - Double(used.count)   // stretches to whatever's been collected
            // red line
            var red = Path(); red.move(to: .init(x: 0, y: y(85))); red.addLine(to: .init(x: w, y: y(85)))
            c.stroke(red, with: .color(.red.opacity(0.35)), style: .init(lineWidth: 1, dash: [2, 3]))
            var line = Path()
            for (i, v) in used.enumerated() {
                let p = CGPoint(x: x(start + Double(i)), y: y(v))
                i == 0 ? line.move(to: p) : line.addLine(to: p)
            }
            var fill = line
            fill.addLine(to: .init(x: x(start + Double(used.count - 1)), y: h)); fill.addLine(to: .init(x: x(start), y: h)); fill.closeSubpath()
            c.fill(fill, with: .linearGradient(Gradient(colors: [color.opacity(0.35), color.opacity(0.02)]), startPoint: .zero, endPoint: .init(x: 0, y: h)))
            c.stroke(line, with: .color(color), style: .init(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            if ahead > 0, let last = used.last {
                var p = Path()
                p.move(to: .init(x: x(span - 1), y: y(last))); p.addLine(to: .init(x: w, y: y(85)))
                c.stroke(p, with: .color(.red), style: .init(lineWidth: 1.6, lineCap: .round, dash: [3, 3]))
            }
        }
    }
}

// MARK: - menu

struct SpaceCard<Content: View>: View {
    let title: String, total: Double?
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer()
                if let total, total > 0 { Text(size(total)).font(.system(size: 12, weight: .bold, design: .rounded)).monospacedDigit() }
            }
            .padding(.horizontal, 8).padding(.bottom, 4)
            content
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.06)))
    }
}

struct SpaceRow: View {
    let name: String, bytes: Double, url: URL, why: String
    @State private var hover = false
    var body: some View {
        HStack(spacing: 8) {
            Text(name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 6)
            if bytes > 0 { Text(size(bytes)).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit() }
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary).opacity(hover ? 1 : 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hover ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        .help(why)
    }
}

struct Section_<Content: View>: View {
    let title: String, trailing: String?
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).kerning(0.6)
                Spacer()
                if let trailing { Text(trailing).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary) }
            }
            content
        }
    }
}

struct Bar: View {
    let fraction: Double, color: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(color.gradient).frame(width: max(4, g.size.width * min(1, fraction)))
            }
        }
    }
}

extension Finding {
    // who left it running
    var culprit: String {
        if let r = detail.range(of: "started by ") {
            let rest = detail[r.upperBound...]
            return String(rest.prefix { $0 != "(" && $0 != "·" && $0 != "," }).trimmingCharacters(in: .whitespaces)
        }
        return kind == .idle ? "Sitting idle" : "Left behind"
    }
    var emoji: String { kind == .hot ? "🔥" : kind == .ghost ? "👻" : kind == .agent ? "🤖" : "💤" }
}

func appIcon(_ name: String) -> NSImage? {
    NSWorkspace.shared.runningApplications.first { $0.localizedName == name }?.icon
}

// what that process actually is, for names nobody recognizes
func whatIs(_ name: String) -> String? {
    let n = name.lowercased()
    let table: [(String, String)] = [
        ("chrome", "browser"), ("safari", "browser"), ("arc", "browser"), ("firefox", "browser"),
        ("xcode", "iOS dev"), ("simulator", "iPhone simulator"), ("simmetalhost", "simulator graphics"),
        ("android studio", "android dev"), ("emulator", "android emulator"), ("gradle", "android builds"), ("kotlin", "android builds"),
        ("java", "runtime"), ("claude", "ai agent"), ("codex", "ai agent"), ("cursor", "code editor"), ("code", "code editor"),
        ("docker", "containers"), ("virtual", "virtual machine"), ("ollama", "local ai model"), ("python", "script"), ("node", "javascript"),
        ("spotify", "music"), ("slack", "chat"), ("discord", "chat"), ("zoom", "calls"), ("wispr", "dictation"),
        ("windowserver", "draws your screen"), ("kernel", "macOS itself"), ("mds", "spotlight indexing"),
    ]
    return table.first { n.contains($0.0) }?.1
}

struct MenuView: View {
    @ObservedObject var m = Model.shared
    @State var tab = 0
    @State var showLeftovers = false
    @State var showLimits = false

    private func limitRow(_ dot: String, _ label: String, _ v: Binding<Int>, _ r: ClosedRange<Int>) -> some View {
        HStack(spacing: 8) {
            Text("\(dot) \(label)").font(.system(size: 12))
            Spacer()
            Text("\(v.wrappedValue)% free").font(.system(size: 12, weight: .semibold)).monospacedDigit()
            Stepper("", value: v, in: r).labelsHidden().controlSize(.small)
        }
    }

    var limits: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WARN ME WHEN").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            limitRow("🟡", "getting tight", $m.warnAt, 5...50)
            limitRow("🔴", "critical", $m.critAt, 2...max(2, m.warnAt - 1))
            HStack(spacing: 8) {
                Text("🟠 heads-up when it's dropping fast").font(.system(size: 12))
                Spacer()
                Toggle("", isOn: $m.trendOn).labelsHidden().toggleStyle(.switch).controlSize(.mini)
            }
            Text("goes red anyway if macOS says memory is critical")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }

    var status: (title: String, line: String) {
        switch m.health {
        case .ok: return ("room to breathe", m.scan.findings.isEmpty ? "nothing to shear right now" : "no need to shear yet")
        case .falling: return ("dropping fast", "you'll hit red in ~\(max(1, Int((m.minutesToRed ?? 1).rounded()))) min")
        case .tight: return ("getting tight", m.scan.findings.isEmpty ? "close an app you're done with" : "shear the leftovers to make room")
        case .critical: return ("about to freeze", m.scan.findings.isEmpty ? "close something big now" : "shear now")
        }
    }

    var groups: [(who: String, items: [Finding])] {
        Dictionary(grouping: m.scan.findings, by: \.culprit)
            .map { ($0.key, $0.value) }
            .sorted { $0.1.reduce(0) { $0 + $1.bytes } > $1.1.reduce(0) { $0 + $1.bytes } }
    }

    var junkTotal: Double { m.junk.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("", selection: $tab) {
                Text("Memory").tag(0)
                Text("Disk").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden()

            if tab == 0 { memory } else { disk }

            if let t = m.toast {
                Text("✓ \(t)").font(.system(size: 12, weight: .medium)).foregroundStyle(.green)
            }

            if showLimits { limits }

            Divider()
            HStack {
                Text(m.freedAll > 0 ? "🐑 baa'd \(size(m.freedToday)) today · \(size(m.freedAll)) all time" : "🐑 nothing baa'd yet")
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button { m.muted.toggle() } label: {
                    Image(systemName: m.muted ? "speaker.slash" : "speaker.wave.2").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help(m.muted ? "baa sound off" : "baa sound on")
                Button { withAnimation(.easeOut(duration: 0.2)) { showLimits.toggle() } } label: {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundStyle(showLimits ? .primary : .secondary).help("warning levels")
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { m.rescan(); m.diskScan(ifOlderThan: 15 * 60) }
    }

    // MARK: memory tab

    @ViewBuilder var memory: some View {
        // the sheep is the gauge
        HStack(spacing: 14) {
            ZStack {
                Sheep(wool: m.wool).frame(width: 86, height: 68)
                    .animation(.spring(response: 0.6, dampingFraction: 0.55), value: m.wool)
                Burst(trigger: m.shears)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(m.free)").font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                    Text("% RAM free").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                }
                HStack(spacing: 5) {
                    Circle().fill(m.health.color).frame(width: 7, height: 7)
                    Text(status.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(m.health == .ok ? Color.primary : m.health.color)
                }
                Text(status.line).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }

        VStack(alignment: .trailing, spacing: 3) {
            Spark(free: m.spark, perMin: m.perMin, minutesToRed: m.minutesToRed, color: m.health.color)
                .frame(height: 30)
            Text("last \(max(1, m.spark.count / 6)) min · swap \(String(format: "%.1f", m.swap)) GB")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
        }

        if !m.scan.findings.isEmpty {
            if m.health == .ok && !showLeftovers {
                // healthy: leftovers stay out of your face
                Button { withAnimation(.snappy) { showLeftovers = true } } label: {
                    HStack {
                        Text("🧶 \(m.scan.findings.count) leftover\(m.scan.findings.count == 1 ? "" : "s") you could shear")
                        Spacer()
                        Text(size(m.scan.freeable)).monospacedDigit().foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                    }
                    .font(.system(size: 12)).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                shearCard
                leftovers
            }
        }

        Section_(title: "USING THE MOST", trailing: nil) {
            let top = m.scan.apps.first?.gb ?? 1
            ForEach(m.scan.apps.prefix(5), id: \.name) { a in
                HStack(spacing: 8) {
                    Group {
                        if let i = appIcon(a.name) { Image(nsImage: i).resizable() }
                        else { Image(systemName: "gearshape.fill").resizable().padding(2).foregroundStyle(.secondary) }
                    }.frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(a.name).font(.system(size: 12)).lineLimit(1)
                        if let w = whatIs(a.name) { Text(w).font(.system(size: 10)).foregroundStyle(.secondary) }
                    }
                    .frame(width: 128, alignment: .leading)
                    Bar(fraction: a.gb / top, color: m.health.color.opacity(0.75)).frame(height: 5)
                    Text(String(format: "%.1f GB", a.gb)).font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(.secondary).frame(width: 46, alignment: .trailing)
                }
            }
        }
    }

    var shearCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(size(m.scan.freeable)).font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
                Text("of wool to shear").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { m.freeAll() } label: {
                Text(m.busy.isEmpty ? "✂️  Shear" : "Shearing…").font(.system(size: 13, weight: .semibold)).padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent).controlSize(.large).disabled(!m.busy.isEmpty)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.08)))
    }

    var leftovers: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(groups, id: \.who) { g in
                VStack(alignment: .leading, spacing: 6) {
                    let n = g.items.count, total = size(g.items.reduce(0) { $0 + $1.bytes })
                    Text(g.items[0].detail.contains("started by ") ? "\(g.who) left \(n == 1 ? "this" : "these") · \(total)" : "\(g.who) · \(total)")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(g.items) { f in
                        HStack(alignment: .center, spacing: 10) {
                            Text(f.emoji).font(.system(size: 14))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Text(f.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Spacer(minLength: 6)
                            Button { m.free(f.id) } label: {
                                Text(m.busy.contains(f.id) ? "Freeing…" : f.freeLabel).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                            .disabled(m.busy.contains(f.id))
                            .fixedSize().layoutPriority(1)
                        }
                    }
                }
            }
        }
    }

    // MARK: disk tab

    @ViewBuilder var disk: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(m.diskTotal > 0 ? String(format: "%.1f", m.diskFree / 1e9) : "…").font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
            Text("GB free").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            Spacer()
            if m.diskTotal > 0 {
                Text("of \(size(m.diskTotal))").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        if m.diskTotal > 0 {
            Bar(fraction: 1 - m.diskFree / m.diskTotal, color: m.diskFree < max(m.diskTotal * 0.1, 15e9) ? .red : .accentColor).frame(height: 6)
        }

        if m.junk.isEmpty {
            VStack(spacing: 4) {
                Text("✨").font(.system(size: 20))
                Text(m.diskTotal > 0 ? "nothing to clean up" : "checking…").font(.system(size: 12, weight: .semibold))
                Text("no old builds or package caches piling up").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 12)
        } else {
            Section_(title: "DEV JUNK", trailing: "\(size(junkTotal)) you can clear") {
                ForEach(m.junk.prefix(6)) { j in
                    HStack(alignment: .center, spacing: 10) {
                        Text(j.icon).font(.system(size: 14))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(j.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Text(j.blockedBy ?? j.detail).font(.system(size: 11))
                                .foregroundStyle(j.blockedBy == nil ? Color.secondary : Color.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Spacer(minLength: 6)
                        Button { m.clean(j.id) } label: {
                            Text(m.busy.contains(j.id) ? "Clearing…" : "\(j.trashes ? "Trash" : "Clear") \(size(j.bytes))")
                                .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(m.busy.contains(j.id) || j.blockedBy != nil)
                        .fixedSize().layoutPriority(1)
                    }
                }
                if m.junk.count > 6 {
                    Text("+\(m.junk.count - 6) more · run baa disk").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        spaceList
    }

    // the junk list only knows safe dev caches. this finds where the rest went, so a full disk is never a mystery.
    // one tap: measure the big folders, then (if there's a claude / pi CLI) ask which are safe. calm on purpose
    @ViewBuilder var spaceList: some View {
        let ai = AI.cli()
        if let v = m.verdicts {
            let known = Set(m.junk.flatMap { j -> [String] in if case .trash(let u) = j.action { return u.map(\.path) }; return [] })
            let safe = v.filter { $0.kind == "safe" && !known.contains($0.url.path) }.prefix(5), rest = v.filter { $0.kind != "safe" }.count
            SpaceCard(title: "✨ Safe to delete", total: safe.reduce(0) { $0 + $1.bytes }) {
                ForEach(safe) { d in SpaceRow(name: d.name, bytes: d.bytes, url: d.url, why: d.why) }
                if safe.isEmpty { Text("nothing that's clearly safe").font(.system(size: 11)).foregroundStyle(.secondary).padding(.vertical, 4) }
            }
            Text((rest > 0 ? "\(rest) more are yours or apps need them · " : "") + "click one to open it")
                .font(.system(size: 10)).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
        } else if let s = m.space, !m.asking {
            SpaceCard(title: "Biggest folders", total: nil) {
                ForEach(Array(s.prefix(5).enumerated()), id: \.offset) { _, d in SpaceRow(name: spaceName(d.url), bytes: d.bytes, url: d.url, why: d.url.path) }
                if s.isEmpty { Text("no big folders in your home · the rest is macOS and apps").font(.system(size: 11)).foregroundStyle(.secondary).padding(.vertical, 4) }
            }
            if let e = m.aiError { Text(e).font(.system(size: 10)).foregroundStyle(.orange).frame(maxWidth: .infinity) }
        } else {
            let busy = m.measuring || m.asking
            Button { m.measureSpace() } label: {
                HStack(spacing: 8) {
                    if busy { ProgressView().controlSize(.small) }
                    Text(m.asking ? "asking \(ai?.name ?? "AI") what's safe…" : m.measuring ? "measuring your folders…" : "✨  Find more space")
                        .font(.system(size: 12, weight: .semibold))
                }
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.08)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(busy)
            if let ai, !busy {
                Text("only folder names + sizes go to \(ai.name) · it never deletes")
                    .font(.system(size: 10)).foregroundStyle(.tertiary).multilineTextAlignment(.center).frame(maxWidth: .infinity)
            }
        }
    }

    func spaceName(_ u: URL) -> String {
        let rel = u.path.replacingOccurrences(of: Disk.home.path + "/", with: "")
        return rel == ".Trash" ? "🗑 Trash (empty it to get this back)" : rel.replacingOccurrences(of: "/", with: " › ")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) { Model.shared.start() }
}

struct BaaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var m = Model.shared
    var body: some Scene {
        MenuBarExtra {
            MenuView()
        } label: {
            if m.health == .ok { Text("🐏 \(m.free)%") }
            else { Text("\(m.health.dot) \(m.free)%") }
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - terminal

enum CLI {
    static func run(_ cmd: String, _ rest: [String]) {
        switch cmd {
        case "--now", "now": now()
        case "--test", "test":
            DistributedNotificationCenter.default().postNotificationName(.init("com.selvi.baa.test"), object: nil, userInfo: nil, deliverImmediately: true)
            print("sent a test notification (Baa needs to be running in the menu bar)")
        case "--free", "free": free(rest.first ?? "")
        case "disk": disk(rest)
        case "warn": warn(rest)
        case "film": film(rest.first ?? "frames")
        case "snapshot": snapshot(rest.first { !$0.hasPrefix("--") } ?? "baa.png", dark: rest.contains("--dark"), demo: rest.contains("--demo"), disk: rest.contains("--disk"))
        default:
            print("baa                  RAM readout + leftovers\nbaa free <id>        free one leftover (or 'all')\nbaa disk             dev junk taking up disk\nbaa disk clean <id>  clear one (or 'all')\nbaa warn <y> [r]     go yellow / red at this % free\nbaa warn --no-trend  turn off the dropping-fast heads-up\nbaa test             sample notification")
        }
    }

    static func warn(_ a: [String]) {
        if a.first == "--no-trend" || a.first == "--trend" {
            Limits.trend = a.first == "--trend"
            print(Limits.trend ? "🟠 dropping-fast heads-up on" : "🟠 dropping-fast heads-up off"); return
        }
        if let y = a.first.flatMap(Int.init), (5...50).contains(y) {
            Limits.warn = y
            if let r = a.dropFirst().first.flatMap(Int.init), r >= 2, r < y { Limits.crit = r }
        } else if !a.isEmpty { print("usage: baa warn <yellow %> [red %]   e.g. baa warn 20 10"); return }
        print("🟡 at \(Limits.warn)% free · 🔴 at \(Limits.crit)% free · 🟠 heads-up \(Limits.trend ? "on" : "off")")
    }

    static func now() {
        let s = Engine().scan(), free = Mem.freePct, h = Health.of(free: free, level: Mem.level, minutesToRed: nil)
        let c = h.ansi, g = "\u{1B}[90m", b = "\u{1B}[1m", r = "\u{1B}[0m"
        let used = 100 - free, fill = used / 5
        print("\n  \(b)RAM\(r)  \(h.dot) \(c)\(b)\(h.word)\(r)")
        print("  \(c)\(String(repeating: "█", count: fill))\(g)\(String(repeating: "░", count: 20 - fill))\(r)  \(b)\(used)% used\(r) \(g)· \(free)% free · swap \(String(format: "%.1f", Mem.swapGB)) GB\(r)\n")
        let top = s.apps.first?.gb ?? 1
        for a in s.apps {
            let n = max(1, Int((a.gb / top * 12).rounded()))
            let name = a.name.count > 18 ? String(a.name.prefix(17)) + "…" : a.name
            print("  \(name.padding(toLength: 19, withPad: " ", startingAt: 0))\(c)\(String(repeating: "▇", count: n))\(g)\(String(repeating: "·", count: 13 - n))\(r) \(String(format: "%5.1f", a.gb)) GB")
        }
        print("")
        if s.findings.isEmpty {
            print("  \(b)leftovers\(r)  \(g)nothing to headbutt ✨\(r)")
        } else {
            print("  \(b)leftovers\(r)  \(g)· \(size(s.freeable)) you can free\(r)")
            for f in s.findings {
                let icon = f.emoji
                print("  \(icon) \(b)\(f.title)\(r)  \(c)\(size(f.bytes))\(r)")
                print("     \(g)\(f.detail)\(r)")
                print("     \(g)→ baa free \(f.id)\(r)")
            }
        }
        if h != .ok { print("\n  \(b)→\(r) \(fixText(s.apps))") }
        print("")
    }

    // draws the real menu panel (live data) to a png, for the readme
    static func snapshot(_ path: String, dark: Bool, demo: Bool = false, disk: Bool = false) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let look = NSAppearance(named: dark ? .darkAqua : .aqua)
        app.appearance = look
        let m = Model.shared
        m.free = Mem.freePct; m.level = Mem.level; m.swap = Mem.swapGB
        m.scan = Engine().scan()
        m.junk = Disk.scan(); m.diskFree = Disk.free; m.diskTotal = Disk.total
        if demo {
            // sample leftovers for readme screenshots (same two baa caught for real while testing)
            m.free = 74; m.level = 1
            m.scan.findings = [
                Finding(id: "demo-1", kind: .ghost, title: "Python · build_index.py", detail: "its terminal or agent closed · idle 12m, running 12m",
                        bytes: 404 * 1_048_576, fix: .kill([])),
                Finding(id: "demo-2", kind: .agent, title: "Dev server :3000 · python", detail: "started by Claude Code (my-app) · idle 12m",
                        bytes: 261 * 1_048_576, fix: .kill([])),
            ]
            m.spark = (0..<180).map { (i: Int) -> Int in let x = Double(i); return Int(70.0 + x * 0.02 + sin(x / 9.0) * 2.5) }
            m.freedToday = 2.3e9; m.freedAll = 48e9
        }
        let panel = MenuView(tab: disk ? 1 : 0, showLeftovers: demo, showLimits: ProcessInfo.processInfo.environment["BAA_SHOW_LIMITS"] != nil)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.1), lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
            .padding(36)
        let host = NSHostingView(rootView: panel)
        host.appearance = look
        host.frame.size = host.fittingSize
        let win = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.appearance = look; win.backgroundColor = .clear; win.isOpaque = false
        win.contentView = host
        host.layoutSubtreeIfNeeded(); host.display()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { print("couldn't render"); return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("saved \(path) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
    }

    // renders the panel frame by frame for the demo video (docs/make_video.py stitches it)
    static func film(_ dir: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let look = NSAppearance(named: .aqua)
        app.appearance = look
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let m = Model.shared
        m.swap = 1.2; m.freedToday = 0; m.freedAll = 44.7e9
        m.scan.apps = Array(Engine().scan().apps.prefix(3))
        m.spark = (0..<180).map { (i: Int) -> Int in Int(74.0 + sin(Double(i) / 9.0) * 2.0) }
        let ease = { (u: Double) -> Double in let x = min(1, max(0, u)); return x * x * (3 - 2 * x) }
        let mb = 1_048_576.0
        let found = [
            Finding(id: "f1", kind: .ghost, title: "Gradle daemon", detail: "Android Studio closed 40m ago · still running", bytes: 1200 * mb, fix: .kill([])),
            Finding(id: "f2", kind: .agent, title: "Dev server :3000 · python", detail: "started by Claude Code (my-app) · idle 12m", bytes: 261 * mb, fix: .kill([])),
            Finding(id: "f3", kind: .ghost, title: "Python · build_index.py", detail: "its terminal or agent closed · idle 12m", bytes: 404 * mb, fix: .kill([])),
        ]
        var log = ""
        var w0 = 0.0
        for f in 0..<270 {
            var free: Double
            if f < 150 { free = 74 - 65 * ease(Double(f) / 150) }
            else if f < 185 { free = 9 }
            else { free = 9 + 54 * ease(Double(f - 185) / 40) }
            m.free = Int(free.rounded())
            m.level = m.free < 15 ? 4 : m.free < 30 ? 2 : 1
            m.spark.append(m.free); m.spark.removeFirst()
            if f < 150 && m.free > 15 { m.perMin = -6; m.minutesToRed = Double(m.free - 15) / 6 } else { m.perMin = f < 185 ? -0.5 : 4; m.minutesToRed = nil }
            m.scan.findings = f >= 180 ? [] : Array(found.prefix(f >= 105 ? 3 : f >= 70 ? 2 : f >= 35 ? 1 : 0))
            m.busy = (170..<180).contains(f) ? ["shearing"] : []
            if f == 179 { w0 = m.wool }
            if f >= 180 && f < 195 { m.filmWool = w0 * (1 - ease(Double(f - 180) / 15)) }
            else if f >= 195 { m.filmWool = Model.woolFor(m.free) * ease(Double(f - 195) / 40) }
            else { m.filmWool = nil }
            m.filmBurst = f >= 180 && f < 214 ? max(0.001, Double(f - 180) / 34) : nil
            m.toast = f >= 186 ? "Freed 1.8 GB · 3 leftovers" : nil
            if f >= 186 { m.freedToday = 1.8e9 * 1.073741824; m.freedAll = 46.5e9 }
            let panel = MenuView(tab: 0, showLeftovers: true)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .transaction { $0.disablesAnimations = true }
            // measure at 1x, then draw scaled up so close-ups stay sharp (BAA_FILM_SCALE=2 -> 4x pixels)
            let k = Double(ProcessInfo.processInfo.environment["BAA_FILM_SCALE"] ?? "1") ?? 1
            let size = NSHostingView(rootView: panel).fittingSize
            let host = NSHostingView(rootView: panel.scaleEffect(k, anchor: .topLeading)
                .frame(width: size.width * k, height: size.height * k, alignment: .topLeading))
            host.appearance = look
            host.frame.size = CGSize(width: size.width * k, height: size.height * k)
            let win = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            win.appearance = look; win.backgroundColor = .clear; win.isOpaque = false
            win.contentView = host
            host.layoutSubtreeIfNeeded(); host.display()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: String(format: "%@/p%04d.png", dir, f)))
            log += "\(f) \(m.free) \(m.health == .ok ? "ok" : m.health.dot)\n"
        }
        try? log.write(toFile: dir + "/state.txt", atomically: true, encoding: .utf8)
        print("rendered 270 frames to \(dir)")
    }

    static func disk(_ rest: [String]) {
        let g = "\u{1B}[90m", b = "\u{1B}[1m", r = "\u{1B}[0m"
        let junk = Disk.scan()
        if rest.first == "clean" {
            let id = rest.dropFirst().first ?? ""
            let picks = id == "all" ? junk.filter { $0.blockedBy == nil } : junk.filter { $0.id == id }
            guard !picks.isEmpty else { print("nothing called '\(id)' right now. run baa disk to see ids"); return }
            for j in picks {
                if let why = j.blockedBy { print("skipped \(j.title): \(why)"); continue }
                Disk.clean(j)
                print(j.trashes ? "moved \(size(j.bytes)) to the Trash · \(j.title)" : "cleared \(size(j.bytes)) · \(j.title)")
            }
            if picks.contains(where: \.trashes) { print("\(g)empty the Trash to get the space back\(r)") }
            return
        }
        let total = Disk.total, free = Disk.free, used = total > 0 ? Int((1 - free / total) * 100) : 0
        let fill = used / 5
        print("\n  \(b)DISK\(r)  \(size(free)) free of \(size(total))")
        print("  \(String(repeating: "█", count: fill))\(g)\(String(repeating: "░", count: 20 - fill))\(r)  \(b)\(used)% used\(r)\n")
        if rest.first == "space" {
            print("  \(b)what's using your space\(r)  \(g)· folders over 1 GB\(r)")
            let sp = Disk.space()
            for d in sp.prefix(12) { print("  \(size(d.bytes).padding(toLength: 9, withPad: " ", startingAt: 0)) \(d.url.path.replacingOccurrences(of: Disk.home.path, with: "~"))") }
            if rest.contains("--ai") {
                print("\n  \(b)ai's take\(r)  \(g)· asking \(AI.cli()?.name ?? "nobody") (names + sizes only)…\(r)")
                switch AI.ask(sp) {
                case .failure(let e): print("  \(e.msg)")
                case .success(let v):
                    for d in v { print("  \(d.chip)  \(b)\(d.url.path.replacingOccurrences(of: Disk.home.path, with: "~"))\(r) \(d.bytes > 0 ? size(d.bytes) : "")\n     \(g)\(d.why)\(r)") }
                }
            } else if AI.cli() != nil { print("\n  \(g)baa disk space --ai asks AI which of these are safe to delete\(r)") }
            print(""); return
        }
        if junk.isEmpty { print("  no dev junk piling up ✨  \(g)(baa disk space shows what is using it)\(r)\n"); return }
        print("  \(b)dev junk\(r)  \(g)· \(size(junk.reduce(0) { $0 + $1.bytes })) you can clear\(r)")
        for j in junk {
            print("  \(j.icon) \(b)\(j.title)\(r)  \(size(j.bytes))")
            print("     \(g)\(j.blockedBy.map { "⚠︎ " + $0 } ?? j.detail)\(r)")
            print("     \(g)→ baa disk clean \(j.id)\(r)")
        }
        print("")
    }

    static func free(_ id: String) {
        let s = Engine().scan()
        let fs = id == "all" ? s.findings : s.findings.filter { $0.id == id }
        guard !fs.isEmpty else { print("nothing called '\(id)' right now. run baa to see ids"); return }
        for f in fs { apply(f, wait: true); print(f.kind == .hot ? "stopped \(f.title)" : "freed \(size(f.bytes)) · \(f.title)") }
    }
}

// Both a login service and a direct launch can start Baa. A process lock keeps
// those paths from creating two menu bar items for the same user.
enum GUIInstance {
    private static var lockFD: Int32 = -1

    static func claim() -> Bool {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.selvi.baa", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            fputs("Baa: cannot create instance lock directory: \(error)\n", stderr)
            return false
        }

        let fd = Darwin.open(directory.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else {
            perror("Baa: cannot open instance lock")
            return false
        }
        guard Darwin.lockf(fd, F_TLOCK, 0) == 0 else {
            Darwin.close(fd)
            return false
        }
        lockFD = fd // Hold the lock until this process exits.
        return true
    }
}

@main
struct Main {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if let cmd = args.first { CLI.run(cmd, Array(args.dropFirst())); return }
        guard GUIInstance.claim() else { return }
        BaaApp.main()
    }
}
