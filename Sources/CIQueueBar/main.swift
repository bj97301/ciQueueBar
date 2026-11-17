import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let client = GitHubClient()
    private let store = Store()
    private let popover = NSPopover()
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.title = "CI …"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggle)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: PanelView(
            store: store,
            onRefresh: { [weak self] in self?.refresh() },
            onConfig: { [weak self] in self?.openConfig() },
            onQuit: { NSApp.terminate(nil) }))
        refresh()
        let interval = max(15, Config.load().refreshSeconds ?? 60)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    @objc private func toggle() {
        guard let b = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil) } else {
            popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        }
    }

    func refresh() {
        guard !store.refreshing else { return }
        store.refreshing = true
        Task {
            do {
                let s = try await client.snapshot(config: Config.load())
                store.snapshot = s
                store.error = nil
            } catch {
                store.error = error.localizedDescription
            }
            store.updated = Date()
            store.refreshing = false
            updateTitle()
        }
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

/// `CIQueueBar --snapshot out.png` renders the panel with live data to a PNG and exits.
@MainActor
func renderSnapshot(to path: String) async {
    let store = Store()
    do { store.snapshot = try await GitHubClient().snapshot(config: Config.load()) } catch { store.error = error.localizedDescription }
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
let args = CommandLine.arguments
let app = NSApplication.shared
if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
    app.setActivationPolicy(.prohibited)
    Task { await renderSnapshot(to: args[i + 1]) }
    app.run()
} else {
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
}
