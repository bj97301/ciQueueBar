import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let client = GitHubClient()
    private var config = Config.load()
    private var timer: Timer?
    private var jobs: [Job] = []
    private var lastError: String?
    private var lastUpdate: Date?
    private var refreshing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.title = "CI …"
        rebuildMenu()
        refresh()
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: max(15, config.refreshSeconds ?? 45), repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    @objc func refresh() {
        guard !refreshing else { return }
        refreshing = true
        config = Config.load()
        Task {
            do {
                let j = try await client.allActiveJobs(config: config)
                await MainActor.run { self.jobs = j; self.lastError = nil }
            } catch {
                await MainActor.run { self.lastError = error.localizedDescription }
            }
            await MainActor.run {
                self.lastUpdate = Date()
                self.refreshing = false
                self.updateTitle()
                self.rebuildMenu()
            }
        }
    }

    private func grouped() -> [(Bucket, queued: [Job], running: [Job])] {
        Bucket.allCases.compactMap { b in
            let js = jobs.filter { Bucket.classify($0.labels) == b }
            guard !js.isEmpty else { return nil }
            return (b, js.filter { $0.status != "in_progress" }.sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) },
                    js.filter { $0.status == "in_progress" })
        }
    }

    private func updateTitle() {
        let g = grouped()
        if lastError != nil && jobs.isEmpty { statusItem.button?.title = "CI ⚠︎"; return }
        if g.isEmpty { statusItem.button?.title = "CI ✓"; return }
        // e.g. "Mac 3⏳1▶  BS 0⏳2▶"
        statusItem.button?.title = g.map { b, q, r in
            var s = b.short + " "
            if !q.isEmpty { s += "\(q.count)⏳" }
            if !r.isEmpty { s += "\(r.count)▶" }
            return s
        }.joined(separator: "  ")
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let g = grouped()
        if let e = lastError { menu.addItem(disabled("⚠︎ \(e)")) }
        if g.isEmpty { menu.addItem(disabled(lastUpdate == nil ? "Loading…" : "No queued or running jobs")) }
        for (b, q, r) in g {
            menu.addItem(NSMenuItem.sectionHeader(title: "\(b.rawValue) — \(q.count) queued, \(r.count) running"))
            for j in q { menu.addItem(jobItem(j, icon: "⏳")) }
            for j in r { menu.addItem(jobItem(j, icon: "▶")) }
        }
        menu.addItem(.separator())
        if let u = lastUpdate {
            let f = DateFormatter(); f.timeStyle = .medium
            menu.addItem(disabled("Updated \(f.string(from: u))"))
        }
        menu.addItem(item("Refresh Now", #selector(refresh), "r"))
        menu.addItem(item("Open Config Folder", #selector(openConfig), ","))
        menu.addItem(item("Quit", #selector(NSApplication.terminate(_:)), "q"))
        statusItem.menu = menu
    }

    private func age(_ d: Date?) -> String {
        guard let d else { return "" }
        let m = Int(Date().timeIntervalSince(d) / 60)
        return m < 60 ? "\(m)m" : "\(m / 60)h\(m % 60)m"
    }

    private func jobItem(_ j: Job, icon: String) -> NSMenuItem {
        let repo = j.repo.split(separator: "/").last.map(String.init) ?? j.repo
        var t = "\(icon) \(repo) · \(j.workflow) / \(j.name)  \(age(j.createdAt))"
        if let r = j.runnerName, !r.isEmpty { t += "  [\(r)]" }
        let it = NSMenuItem(title: t, action: #selector(openJob(_:)), keyEquivalent: "")
        it.target = self
        it.representedObject = j.url
        it.toolTip = j.labels.joined(separator: ", ")
        return it
    }

    private func disabled(_ t: String) -> NSMenuItem {
        let it = NSMenuItem(title: t, action: nil, keyEquivalent: ""); it.isEnabled = false; return it
    }

    private func item(_ t: String, _ s: Selector, _ k: String) -> NSMenuItem {
        let it = NSMenuItem(title: t, action: s, keyEquivalent: k)
        it.target = s == #selector(NSApplication.terminate(_:)) ? NSApp : self
        return it
    }

    @objc func openJob(_ sender: NSMenuItem) {
        if let u = sender.representedObject as? URL { NSWorkspace.shared.open(u) }
    }

    @objc func openConfig() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/ciqueuebar")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
