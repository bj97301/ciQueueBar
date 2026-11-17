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
            func ref(_ j: Job) -> JobRef { JobRef(r: j.repoShort, br: j.branch, w: j.workflow, n: j.name) }
            refs[g.bucket.key] = JobRefs(q: g.queued.map(ref), run: g.running.map(ref))
        }
        // Attribute each runner's CPU to the job it's running.
        let usage: [JobCPU] = groups.flatMap(\.running).compactMap { j in
            guard let rn = j.runnerName, let c = mean[rn], c >= 0.02 else { return nil }
            return JobCPU(r: j.repoShort, br: j.branch, w: j.workflow, n: j.name, rn: rn, c: c)
        }
        store.history.append(Sample(t: Date().timeIntervalSince1970, b: b, c: mean.filter { $0.value >= 0.05 }, j: refs, u: usage))
        store.historyVersion += 1
    }

    private func updateTitle() {
        let active = store.snapshot.groups.filter { !$0.queued.isEmpty || !$0.running.isEmpty }
        if store.error != nil && store.snapshot.jobs.isEmpty { statusItem.button?.title = "CI ⚠︎"; return }
        if active.isEmpty { statusItem.button?.title = "CI ✓"; return }
        // e.g. "Mac 3⏳1▶  BS 2▶"
        statusItem.button?.title = active.map { g in
            var s = g.bucket.short + " "
            if !g.queued.isEmpty { s += "\(g.queued.count)⏳" }
            if !g.running.isEmpty { s += "\(g.running.count)▶" }
            return s
        }.joined(separator: "  ")
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
