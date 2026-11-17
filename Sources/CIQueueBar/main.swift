import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let client = GitHubClient()
    private let sampler = CPUSampler()
    private let store = Store()
    private let popover = NSPopover()
    private var timers: [Timer] = []
    private var outsideClickMonitor: Any?
    /// CPU samples accumulated between history records, so each record holds the mean.
    private var cpuSum: [String: Double] = [:]
    private var cpuCount = 0
    /// Last 30 CPU samples (10 s apart) split into Mac / Linux cores, for the menu bar graph.
    private var cpuTrail: [(mac: Double, linux: Double)] = []
    private let hostCores = Double(ProcessInfo.processInfo.activeProcessorCount)
    private var escMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.title = "CI …"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggle)
        popover.behavior = .transient
        popover.delegate = self
        let host = NSHostingController(rootView: PanelView(
            store: store,
            onRefresh: { [weak self] in self?.refresh() },
            onConfig: { [weak self] in self?.openConfig() },
            onQuit: { NSApp.terminate(nil) }))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        refresh()
        sampleCPU()
        let interval = max(15, Config.load().refreshSeconds ?? 60)
        timers.append(Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleCPU() }
        })
    }

    @objc private func toggle() {
        guard let b = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        // Room for header + footer + popover chrome; content grows up to the rest.
        let screen = b.window?.screen ?? NSScreen.main
        store.maxHeight = max(300, (screen?.visibleFrame.height ?? 900) - 130)
        let fitsTwo = (screen?.visibleFrame.width ?? 1600) >= columnWidth * 2 + 60 * UIScale
        store.columns = Config.load().columns.map { min(2, max(1, $0)) } ?? (fitsTwo ? 2 : 1)
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        // Take keyboard focus (you just clicked us) so Esc reaches the panel; focus goes back on close.
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 { self?.popover.performClose(nil); return nil }   // Esc
            return e
        }
        // Clicks in other apps don't reach a transient popover of an inactive app; close on any of them.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.popover.performClose(nil) }
        }
        if let u = store.updated, Date().timeIntervalSince(u) > 20 { refresh() }
        sampleCPU()
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor in
            if let m = outsideClickMonitor { NSEvent.removeMonitor(m); outsideClickMonitor = nil }
            if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
            // Give focus back to whatever app was in front before the click.
            if NSApp.isActive { NSApp.hide(nil) }
        }
    }

    func refresh() {
        guard !store.refreshing else { return }
        store.refreshing = true
        Task {
            do {
                let config = Config.load()
                let s = try await client.snapshot(config: config)
                store.snapshot = s
                store.error = nil
                recordSample()
                if store.history.samples.count <= 1 {
                    let older = await client.backfill(config: config, runners: s.runners)
                    store.history.merge(older)
                    store.historyVersion += 1
                }
            } catch {
                store.error = error.localizedDescription
            }
            store.updated = Date()
            store.refreshing = false
            updateTitle()
        }
    }

    private func sampleCPU() {
        let hosts = Config.load().sshCpuHosts ?? []
        let sampler = sampler
        Task.detached {
            let c = sampler.sample(sshHosts: hosts)
            await MainActor.run {
                self.store.cpu = c
                for (k, v) in c { self.cpuSum[k, default: 0] += v }
                self.cpuCount += 1
                self.pushTrail(c)
                self.updateTitle()
            }
        }
    }

    private func recordSample() {
        let n = Double(max(cpuCount, 1))
        let mean = cpuCount > 0 ? cpuSum.mapValues { $0 / n } : store.cpu
        cpuSum = [:]; cpuCount = 0
        var b: [String: [Double]] = [:]
        let groups = store.snapshot.groups
        for bucket in Bucket.allCases {
            let g = groups.first { $0.bucket == bucket }
            let cpu = (g?.runners.isEmpty ?? true) ? -1 : g!.runners.reduce(0) { $0 + (mean[$1.name] ?? 0) }
            b[bucket.key] = [Double(g?.queued.count ?? 0), Double(g?.running.count ?? 0), cpu]
        }
        var refs: [String: JobRefs] = [:]
        for g in groups {
            func ref(_ j: Job) -> JobRef { JobRef(r: j.repoShort, br: j.branch, w: j.workflow, n: j.name, t: j.t3?.title) }
            refs[g.bucket.key] = JobRefs(q: g.queued.map(ref), run: g.running.map(ref))
        }
        // Attribute each runner's CPU to the job it's running.
        let usage: [JobCPU] = groups.flatMap(\.running).compactMap { j in
            guard let rn = j.runnerName, let c = mean[rn], c >= 0.02 else { return nil }
            return JobCPU(r: j.repoShort, br: j.branch, w: j.workflow, n: j.name, rn: rn, c: c, t: j.t3?.title)
        }
        store.history.append(Sample(t: Date().timeIntervalSince1970, b: b, c: mean.filter { $0.value >= 0.05 }, j: refs, u: usage))
        store.historyVersion += 1
    }

    private func pushTrail(_ c: [String: Double]) {
        var mac = 0.0, linux = 0.0
        let runners = Dictionary(store.snapshot.runners.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        for (name, v) in c {
            let isLinux = runners[name].map { Bucket.forRunner($0) == .linux } ?? name.lowercased().contains("linux")
            if isLinux { linux += v } else { mac += v }
        }
        cpuTrail.append((mac, linux))
        if cpuTrail.count > 30 { cpuTrail.removeFirst(cpuTrail.count - 30) }
    }

    /// Menu bar: CPU graph + "CI CPU % of this Mac" + queue counts, e.g. [▁▃▇] 35%  Mac 2▶  BS 1⏳
    private func updateTitle() {
        guard let button = statusItem.button else { return }
        let active = store.snapshot.groups.filter { !$0.queued.isEmpty || !$0.running.isEmpty }
        let now = cpuTrail.last.map { $0.mac + $0.linux } ?? 0
        var parts: [String] = []
        if !cpuTrail.isEmpty { parts.append(String(format: "%.0f%%", 100 * now / max(1, hostCores))) }
        if store.error != nil && store.snapshot.jobs.isEmpty {
            parts.append("CI ⚠︎")
        } else if active.isEmpty {
            parts.append(cpuTrail.isEmpty ? "CI ✓" : "✓")
        } else {
            parts += active.map { g in
                var s = g.bucket.short + " "
                if !g.queued.isEmpty { s += "\(g.queued.count)⏳" }
                if !g.running.isEmpty { s += "\(g.running.count)▶" }
                return s
            }
        }
        button.attributedTitle = NSAttributedString(
            string: " " + parts.joined(separator: "  "),
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)])
        button.image = cpuTrail.isEmpty ? nil : cpuGraph()
        button.imagePosition = .imageLeft
        button.toolTip = String(format: "CI CPU: %.1f cores (Mac %.1f, Linux %.1f) of %.0f", now,
                                cpuTrail.last?.mac ?? 0, cpuTrail.last?.linux ?? 0, hostCores)
    }

    /// iStat-style bar graph of the last 5 minutes: Linux (green) stacked under Mac (blue), full height = all cores.
    private func cpuGraph() -> NSImage {
        let bars = 30, barW: CGFloat = 1.5, h: CGFloat = 16
        let size = NSSize(width: CGFloat(bars) * barW + 2, height: h)
        let trail = Array(repeating: (mac: 0.0, linux: 0.0), count: max(0, bars - cpuTrail.count)) + cpuTrail.suffix(bars)
        let cap = max(1, hostCores)
        let img = NSImage(size: size, flipped: false) { rect in
            NSColor.labelColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
            for (i, v) in trail.enumerated() {
                let x = 1 + CGFloat(i) * barW
                let lh = CGFloat(min(1, v.linux / cap)) * (h - 2)
                let mh = CGFloat(min(1, (v.linux + v.mac) / cap)) * (h - 2) - lh
                NSColor.systemGreen.setFill()
                NSRect(x: x, y: 1, width: barW, height: lh).fill()
                NSColor.systemBlue.setFill()
                NSRect(x: x, y: 1 + lh, width: barW, height: max(0, mh)).fill()
            }
            return true
        }
        img.isTemplate = false
        return img
    }

    private func openConfig() {
        try? FileManager.default.createDirectory(at: Config.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Config.directory)
    }
}

/// `CIQueueBar --snapshot out.png [--period 1H|6H|1D|7D|30D]` renders the panel with live data to a PNG and exits.
@MainActor
func renderSnapshot(to path: String, period: Period?, group: CPUGroup?, hover: (String, Date)?) async {
    let store = Store()
    store.persist = false
    if let group { store.cpuGroup = group }
    store.pinnedHover = hover
    if let period { store.period = period }
    let config = Config.load()
    let sampler = CPUSampler()
    _ = sampler.sample(sshHosts: config.sshCpuHosts ?? [])   // prime Linux CPU deltas
    do { store.snapshot = try await GitHubClient().snapshot(config: config) } catch { store.error = error.localizedDescription }
    try? await Task.sleep(nanoseconds: 2_000_000_000)
    store.cpu = sampler.sample(sshHosts: config.sshCpuHosts ?? [])
    store.updated = Date()
    let view = PanelView(store: store, scrolls: false)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .dark)
    let r = ImageRenderer(content: view)
    r.scale = 2
    guard let img = r.cgImage else { print("render failed"); exit(1) }
    let rep = NSBitmapImageRep(cgImage: img)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
    exit(0)
}

MainActor.assumeIsolated {
    UIScale = CGFloat(min(4, max(0.5, Config.load().textScale ?? 1.5)))
    let args = CommandLine.arguments
    let app = NSApplication.shared
    // --match owner/repo branch [pr...]: print the T3 thread a run would link to.
    if let i = args.firstIndex(of: "--match"), i + 2 < args.count {
        let idx = T3Index()
        idx.refresh(dbPath: Config.load().t3StateDb)
        let link = idx.link(repo: args[i + 1], branch: args[i + 2], prNumbers: args.dropFirst(i + 3).compactMap { Int($0) })
        print(link.map { "\($0.title) [\($0.via)] \($0.url)" } ?? "no match")
        exit(0)
    }
    if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
        let period = args.firstIndex(of: "--period").flatMap { $0 + 1 < args.count ? Period(rawValue: args[$0 + 1]) : nil }
        app.setActivationPolicy(.prohibited)
        // --hover <chart id> <unix time>: show that chart's hover card at that moment.
        // Chart ids: queue-<bucket>, cpu-<bucket>, cpu-group (bucket: mac, linux, blacksmith, github, other).
        let hover: (String, Date)? = args.firstIndex(of: "--hover").flatMap { i in
            guard i + 2 < args.count, let t = Double(args[i + 2]) else { return nil }
            return (args[i + 1], Date(timeIntervalSince1970: t))
        }
        let group = args.firstIndex(of: "--group").flatMap { $0 + 1 < args.count ? CPUGroup(rawValue: args[$0 + 1]) : nil }
        Task { await renderSnapshot(to: args[i + 1], period: period, group: group, hover: hover) }
        app.run()
    } else {
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
