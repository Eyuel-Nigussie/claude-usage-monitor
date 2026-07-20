// Claude Usage Monitor — minimal macOS menu bar widget
// Mirrors claude.ai's "Usage" panel: Session (5hr) and Weekly (7 day)
// utilization with reset times, fetched from the Claude Code OAuth endpoint.
// Optional always-on-top floating mini-widget (toggle from the menu).
// Local transcript parsing survives only in the --stats diagnostic CLI.

import AppKit
import Security
import ServiceManagement

// MARK: - Usage entries

struct UsageEntry {
    let date: Date
    let model: String
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite5m = 0
    var cacheWrite1h = 0

    var totalTokens: Int { input + output + cacheRead + cacheWrite5m + cacheWrite1h }
}

struct Totals {
    var input = 0, output = 0, cacheRead = 0, cacheWrite = 0
    var tokens: Int { input + output + cacheRead + cacheWrite }

    init(_ entries: [UsageEntry]) {
        for e in entries {
            input += e.input
            output += e.output
            cacheRead += e.cacheRead
            cacheWrite += e.cacheWrite5m + e.cacheWrite1h
        }
    }
}

// MARK: - JSONL scanner

enum UsageScanner {
    static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func loadEntries(since cutoff: Date) -> [UsageEntry] {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        guard let projects = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }

        var byId: [String: UsageEntry] = [:]
        var anonymous: [UsageEntry] = []

        for project in projects {
            guard let files = try? fm.contentsOfDirectory(at: project, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                guard let mtime, mtime >= cutoff else { continue }
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                for line in text.split(separator: "\n") where line.contains("\"usage\"") {
                    parseLine(String(line), cutoff: cutoff, into: &byId, anonymous: &anonymous)
                }
            }
        }
        return (Array(byId.values) + anonymous).sorted { $0.date < $1.date }
    }

    private static func parseLine(_ line: String, cutoff: Date,
                                  into byId: inout [String: UsageEntry],
                                  anonymous: inout [UsageEntry]) {
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (obj["type"] as? String) == "assistant",
              let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let ts = obj["timestamp"] as? String,
              let date = isoFrac.date(from: ts) ?? isoPlain.date(from: ts),
              date >= cutoff
        else { return }

        let model = (message["model"] as? String) ?? "unknown"
        guard model != "<synthetic>" else { return }

        var entry = UsageEntry(date: date, model: model)
        entry.input = usage["input_tokens"] as? Int ?? 0
        entry.output = usage["output_tokens"] as? Int ?? 0
        entry.cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
        if let cc = usage["cache_creation"] as? [String: Any] {
            entry.cacheWrite5m = cc["ephemeral_5m_input_tokens"] as? Int ?? 0
            entry.cacheWrite1h = cc["ephemeral_1h_input_tokens"] as? Int ?? 0
        } else {
            entry.cacheWrite5m = usage["cache_creation_input_tokens"] as? Int ?? 0
        }
        guard entry.totalTokens > 0 else { return }

        // Dedupe: the same message can be re-written across lines; keep the latest.
        let messageId = message["id"] as? String
        let requestId = obj["requestId"] as? String
        if messageId != nil || requestId != nil {
            byId["\(messageId ?? "-"):\(requestId ?? "-")"] = entry
        } else {
            anonymous.append(entry)
        }
    }
}

// MARK: - Plan limits (real utilization from the Claude Code OAuth endpoint)

struct LimitWindow {
    let key: String
    let label: String
    let utilization: Double // 0–100
    let resetsAt: Date?
}

enum LimitsFetcher {
    // Reads the Claude Code OAuth access token from the login Keychain.
    // The token is used only for the local HTTPS call below and is never logged.
    //
    // Primary path goes through /usr/bin/security (an Apple-signed binary):
    // its Keychain approval is stable, so one "Always Allow" survives rebuilds
    // of this app. Direct SecItemCopyMatching is the fallback — its approval is
    // tied to this app's code signature and resets on every rebuild.
    static var debugLog: [String] = []

    static func accessToken() -> String? {
        tokenViaSecurityCLI() ?? tokenViaKeychainAPI()
    }

    private static func token(fromCredentials data: Data) -> String? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String
        else { return nil }
        return token
    }

    private static func tokenViaSecurityCLI() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        p.standardOutput = out
        let err = Pipe()
        p.standardError = err
        do { try p.run() } catch {
            debugLog.append("cli: spawn failed: \(error.localizedDescription)")
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else {
            let msg = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            debugLog.append("cli: exit \(p.terminationStatus) \(msg)")
            return nil
        }
        let token = token(fromCredentials: Data(text.utf8))
        debugLog.append(token == nil ? "cli: got payload but no accessToken key" : "cli: token ok")
        return token
    }

    private static func tokenViaKeychainAPI() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            debugLog.append("api: SecItemCopyMatching status \(status)")
            return nil
        }
        let token = token(fromCredentials: data)
        debugLog.append(token == nil ? "api: got payload but no accessToken key" : "api: token ok")
        return token
    }

    static let knownLabels: [String: String] = [
        "five_hour": "Session (5hr)",
        "seven_day": "Weekly (7 day)",
        "seven_day_sonnet": "Weekly · Sonnet",
        "seven_day_opus": "Weekly · Opus",
    ]

    static func fetch(completion: @escaping ([LimitWindow]?) -> Void) {
        // Token retrieval may block (subprocess / Keychain prompt) — keep it off the main thread.
        DispatchQueue.global(qos: .utility).async { fetchSync(completion: completion) }
    }

    private static func fetchSync(completion: @escaping ([LimitWindow]?) -> Void) {
        if debugLog.count > 40 { debugLog.removeFirst(debugLog.count - 40) }
        guard let token = accessToken(),
              let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            debugLog.append("fetch: no token available")
            completion(nil)
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        // Note: completion is called on a background queue.
        URLSession.shared.dataTask(with: req) { data, response, _ in
            var windows: [LimitWindow]?
            defer { completion(windows) }
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard let data,
                  status == 200,
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else {
                debugLog.append("fetch: http \(status), body: \(data.flatMap { String(data: $0.prefix(200), encoding: .utf8) } ?? "none")")
                return
            }

            var found: [LimitWindow] = []
            for (key, value) in obj {
                guard let w = value as? [String: Any],
                      let utilization = w["utilization"] as? Double else { continue }
                let resets = (w["resets_at"] as? String).flatMap {
                    UsageScanner.isoFrac.date(from: $0) ?? UsageScanner.isoPlain.date(from: $0)
                }
                let label = knownLabels[key] ?? key.replacingOccurrences(of: "_", with: " ").capitalized
                found.append(LimitWindow(key: key, label: label, utilization: utilization, resetsAt: resets))
            }
            // Stable order: session first, then week, then anything else.
            let order = ["five_hour", "seven_day", "seven_day_sonnet", "seven_day_opus"]
            found.sort {
                (order.firstIndex(of: $0.key) ?? .max, $0.key) < (order.firstIndex(of: $1.key) ?? .max, $1.key)
            }
            windows = found.isEmpty ? nil : found
        }.resume()
    }
}

// MARK: - 5-hour session blocks

struct SessionBlock {
    let start: Date
    var entries: [UsageEntry]
    var end: Date { start.addingTimeInterval(5 * 3600) }
}

func activeBlock(in entries: [UsageEntry], now: Date) -> SessionBlock? {
    var blocks: [SessionBlock] = []
    var lastDate: Date?
    for e in entries {
        let floored = Date(timeIntervalSince1970: floor(e.date.timeIntervalSince1970 / 3600) * 3600)
        if var current = blocks.last,
           e.date < current.end,
           let last = lastDate, e.date.timeIntervalSince(last) < 5 * 3600 {
            current.entries.append(e)
            blocks[blocks.count - 1] = current
        } else {
            blocks.append(SessionBlock(start: floored, entries: [e]))
        }
        lastDate = e.date
    }
    guard let block = blocks.last, let last = lastDate,
          now < block.end, now.timeIntervalSince(last) < 5 * 3600 else { return nil }
    return block
}

// MARK: - Formatting

func fmtTokens(_ n: Int) -> String {
    switch n {
    case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
    case 1_000...:     return String(format: "%.1fK", Double(n) / 1_000)
    default:           return "\(n)"
    }
}

func fmtRemaining(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(seconds))
    return String(format: "%dh %02dm", s / 3600, (s % 3600) / 60)
}

let weekdayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "EEE HH:mm"
    return f
}()

func fmtReset(_ date: Date?, now: Date) -> String {
    guard let date else { return "" }
    let interval = date.timeIntervalSince(now)
    if interval < 24 * 3600 { return "resets in \(fmtRemaining(interval))" }
    return "resets \(weekdayFormatter.string(from: date))"
}

func fmtPercent(_ p: Double) -> String { "\(Int(p.rounded()))%" }

// Matches claude.ai's usage panel phrasing: "Resets in 2h".
func fmtResetIn(_ date: Date?, now: Date) -> String {
    guard let date else { return "" }
    let s = max(0, Int(date.timeIntervalSince(now)))
    if s >= 24 * 3600 {
        let d = s / 86400, h = (s % 86400) / 3600
        return h > 0 ? "Resets in \(d)d \(h)h" : "Resets in \(d)d"
    }
    if s >= 3600 { return "Resets in \(s / 3600)h" }
    return "Resets in \(max(1, s / 60))m"
}

// MARK: - Floating widget

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class BarView: NSView {
    var fraction: CGFloat = 0 { didSet { needsDisplay = true } }
    var colorByLevel = false
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
        guard fraction > 0 else { return }
        var fill = r
        fill.size.width = max(r.height, r.width * min(1, fraction))
        let color: NSColor = colorByLevel
            ? (fraction >= 0.9 ? .systemRed : fraction >= 0.75 ? .systemOrange : .controlAccentColor)
            : .controlAccentColor
        color.setFill()
        NSBezierPath(roundedRect: fill, xRadius: r.height / 2, yRadius: r.height / 2).fill()
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    let menu = NSMenu()
    var timer: Timer?

    var panel: FloatingPanel?
    var panelSessionPct: NSTextField?
    var panelSessionSub: NSTextField?
    var panelWeekPct: NSTextField?
    var panelWeekSub: NSTextField?
    var panelBar: BarView?
    var panelWeekBar: BarView?

    var limits: [LimitWindow]?
    var lastLimitsFetch = Date.distantPast

    var sessionLimit: LimitWindow? { limits?.first { $0.key == "five_hour" } }
    var weekLimit: LimitWindow? { limits?.first { $0.key == "seven_day" } }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.title = "✳ …"
        }
        menu.delegate = self
        statusItem.menu = menu

        refresh()
        // 30 s tick keeps the countdowns fresh; the network fetch inside is
        // throttled separately (5 min).
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }

        if UserDefaults.standard.bool(forKey: "showFloatingWidget") { showPanel() }
    }

    // MARK: Data

    func refresh() {
        let now = Date()
        updateStatusTitle(now: now)
        updatePanel(now: now)
        fetchLimitsIfNeeded(now: now)
    }

    func fetchLimitsIfNeeded(now: Date) {
        // Polite cadence: the usage endpoint tolerates only occasional requests —
        // even 1/min has triggered 429s. 5-minute staleness is fine for a gauge.
        guard now.timeIntervalSince(lastLimitsFetch) >= 300 else { return }
        lastLimitsFetch = now
        LimitsFetcher.fetch { [weak self] windows in
            DispatchQueue.main.async {
                guard let self else { return }
                if windows != nil {
                    self.limits = windows
                } else {
                    // Failed (rate limit, offline, token) — back off ~10 minutes total.
                    self.lastLimitsFetch = Date().addingTimeInterval(300)
                }
                let now = Date()
                self.updateStatusTitle(now: now)
                self.updatePanel(now: now)
            }
        }
    }

    // MARK: Status bar

    func updateStatusTitle(now: Date) {
        guard let button = statusItem.button else { return }
        if let session = sessionLimit {
            var title = "✳ \(fmtPercent(session.utilization))"
            if let week = weekLimit, week.utilization >= 80 {
                title += "  wk \(fmtPercent(week.utilization))"
            }
            button.title = title
        } else {
            button.title = "✳ …"
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
        menu.removeAllItems()
        let now = Date()

        menu.addItem(header("Usage"))
        if let limits {
            for w in limits {
                menu.addItem(info("\(w.label):  \(fmtPercent(w.utilization))   ·   \(fmtResetIn(w.resetsAt, now: now))"))
            }
        } else {
            menu.addItem(info("Waiting for data — allow Keychain access"))
            menu.addItem(info("if prompted; retries every few minutes"))
        }
        menu.addItem(.separator())

        let floating = NSMenuItem(title: "Floating Widget", action: #selector(toggleFloating), keyEquivalent: "f")
        floating.target = self
        floating.state = (panel?.isVisible == true) ? .on : .off
        menu.addItem(floating)

        if Bundle.main.bundleIdentifier != nil, Bundle.main.bundlePath.hasSuffix(".app") {
            let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
            login.target = self
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(login)
        }

        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        return item
    }

    func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular),
        ])
        return item
    }

    // MARK: Floating widget

    @objc func toggleFloating() {
        if panel?.isVisible == true {
            panel?.orderOut(nil)
            UserDefaults.standard.set(false, forKey: "showFloatingWidget")
        } else {
            showPanel()
            UserDefaults.standard.set(true, forKey: "showFloatingWidget")
        }
    }

    func showPanel() {
        if panel == nil { buildPanel() }
        updatePanel(now: Date())
        panel?.orderFrontRegardless()
    }

    func buildPanel() {
        let size = NSSize(width: 230, height: 128)
        let p = FloatingPanel(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        p.contentView = effect

        let headerLabel = NSTextField(labelWithString: "USAGE")
        headerLabel.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        headerLabel.textColor = .secondaryLabelColor
        headerLabel.frame = NSRect(x: 14, y: 106, width: size.width - 28, height: 14)
        effect.addSubview(headerLabel)

        func nameLabel(_ text: String, y: CGFloat) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            l.font = NSFont.systemFont(ofSize: 13, weight: .regular)
            l.frame = NSRect(x: 14, y: y, width: 150, height: 17)
            effect.addSubview(l)
            return l
        }
        func pctLabel(y: CGFloat) -> NSTextField {
            let l = NSTextField(labelWithString: "–")
            l.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
            l.alignment = .right
            l.frame = NSRect(x: size.width - 74, y: y, width: 60, height: 17)
            effect.addSubview(l)
            return l
        }
        func subLabel(y: CGFloat) -> NSTextField {
            let l = NSTextField(labelWithString: "")
            l.font = NSFont.systemFont(ofSize: 11, weight: .regular)
            l.textColor = .secondaryLabelColor
            l.frame = NSRect(x: 14, y: y, width: size.width - 28, height: 14)
            effect.addSubview(l)
            return l
        }
        func barView(y: CGFloat) -> BarView {
            let b = BarView(frame: NSRect(x: 14, y: y, width: size.width - 28, height: 4))
            b.colorByLevel = true
            effect.addSubview(b)
            return b
        }

        _ = nameLabel("Session (5hr)", y: 84)
        panelSessionPct = pctLabel(y: 84)
        panelBar = barView(y: 77)
        panelSessionSub = subLabel(y: 60)

        _ = nameLabel("Weekly (7 day)", y: 38)
        panelWeekPct = pctLabel(y: 38)
        panelWeekBar = barView(y: 31)
        panelWeekSub = subLabel(y: 14)

        panel = p

        p.setFrameAutosaveName("ClaudeUsageFloatingWidget")
        if !p.setFrameUsingName("ClaudeUsageFloatingWidget"), let screen = NSScreen.main {
            let v = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: v.maxX - size.width - 16, y: v.maxY - size.height - 12))
        }
        p.setContentSize(size) // restored frames may carry an older size
    }

    func updatePanel(now: Date) {
        guard let panel, panel.isVisible else { return }

        if let session = sessionLimit {
            panelSessionPct?.stringValue = fmtPercent(session.utilization)
            panelBar?.fraction = CGFloat(session.utilization / 100)
            panelSessionSub?.stringValue = fmtResetIn(session.resetsAt, now: now)
        } else {
            panelSessionPct?.stringValue = "–"
            panelBar?.fraction = 0
            panelSessionSub?.stringValue = "waiting for data"
        }
        if let week = weekLimit {
            panelWeekPct?.stringValue = fmtPercent(week.utilization)
            panelWeekBar?.fraction = CGFloat(week.utilization / 100)
            panelWeekSub?.stringValue = fmtResetIn(week.resetsAt, now: now)
        } else {
            panelWeekPct?.stringValue = "–"
            panelWeekBar?.fraction = 0
            panelWeekSub?.stringValue = ""
        }
    }

    // MARK: Launch at login

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Launch at Login toggle failed: \(error)")
        }
    }
}

// MARK: - CLI stats mode (for testing: ./ClaudeUsageMonitor --stats)

func printStats() {
    let now = Date()
    let entries = UsageScanner.loadEntries(since: now.addingTimeInterval(-24 * 3600))
    print("entries (24h): \(entries.count)")
    let startOfDay = Calendar.current.startOfDay(for: now)
    let today = entries.filter { $0.date >= startOfDay }
    let tt = Totals(today)
    print("today: tokens=\(fmtTokens(tt.tokens))  in=\(fmtTokens(tt.input)) out=\(fmtTokens(tt.output)) cacheR=\(fmtTokens(tt.cacheRead)) cacheW=\(fmtTokens(tt.cacheWrite))")
    if let block = activeBlock(in: entries, now: now) {
        let bt = Totals(block.entries)
        print("active block: started \(block.start), resets in \(fmtRemaining(block.end.timeIntervalSince(now))), tokens \(fmtTokens(bt.tokens))")
    } else {
        print("active block: none")
    }

    let semaphore = DispatchSemaphore(value: 0)
    var fetched: [LimitWindow]?
    LimitsFetcher.fetch { windows in
        fetched = windows
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 60)
    if let fetched {
        for w in fetched {
            print("limit \(w.label): \(fmtPercent(w.utilization))  \(fmtReset(w.resetsAt, now: now))")
        }
    } else {
        print("limits: unavailable (no Keychain access or token expired)")
    }
    for line in LimitsFetcher.debugLog { print("debug: \(line)") }
}

// MARK: - Main

if CommandLine.arguments.contains("--stats") {
    printStats()
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--login"), CommandLine.arguments.indices.contains(i + 1) {
    let mode = CommandLine.arguments[i + 1]
    do {
        if mode == "on" { try SMAppService.mainApp.register() }
        else { try SMAppService.mainApp.unregister() }
        print("launch at login: \(mode)")
    } catch {
        print("launch at login failed: \(error.localizedDescription)")
    }
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
