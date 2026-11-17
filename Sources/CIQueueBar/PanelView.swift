import SwiftUI

final class Store: ObservableObject {
    @Published var snapshot = Snapshot()
    @Published var error: String?
    @Published var updated: Date?
    @Published var refreshing = false
}

struct PanelView: View {
    @ObservedObject var store: Store
    var scrolls = true
    var onRefresh: () -> Void = {}
    var onConfig: () -> Void = {}
    var onQuit: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if scrolls {
                ScrollView { content }.frame(maxHeight: 720)
            } else {
                content
            }
            Divider()
            footer
        }
        .frame(width: 600)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("CI Queue").font(.headline)
            Spacer()
            ForEach(store.snapshot.groups) { g in
                HStack(spacing: 4) {
                    Image(systemName: g.bucket.symbol)
                    Text("\(g.queued.count)").foregroundStyle(g.queued.isEmpty ? Color.secondary : Color.orange)
                    Text("/")
                        .foregroundStyle(.tertiary)
                    Text("\(g.running.count)").foregroundStyle(g.running.isEmpty ? Color.secondary : Color.blue)
                }
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .help("\(g.bucket.rawValue): queued / running")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let e = store.error {
                Label(e, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.callout)
            }
            if store.updated == nil {
                HStack { ProgressView().controlSize(.small); Text("Loading…").foregroundStyle(.secondary) }
            } else if store.snapshot.groups.isEmpty {
                Text("No queued or running jobs").foregroundStyle(.secondary)
            }
            ForEach(store.snapshot.groups) { g in BucketSection(group: g) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func iconButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .help(help)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let u = store.updated {
                Text("Updated \(u.formatted(date: .omitted, time: .standard))")
            }
            Text("\(store.snapshot.repoCount) repos")
            if let r = store.snapshot.rateRemaining, let l = store.snapshot.rateLimit {
                Text("API \(r)/\(l)")
            }
            Spacer()
            if store.refreshing { ProgressView().controlSize(.mini) }
            iconButton("arrow.clockwise", "Refresh now", onRefresh)
            iconButton("gearshape", "Open config folder", onConfig)
            iconButton("power", "Quit", onQuit)
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}

struct BucketSection: View {
    let group: BucketGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(group.bucket.rawValue, systemImage: group.bucket.symbol).font(.system(size: 13, weight: .bold))
                Spacer()
                Text("\(group.queued.count) queued · \(group.running.count) running")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if let w = group.longestWait {
                    Text("oldest wait \(shortDuration(w))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(w > 600 ? .red : .orange)
                }
            }
            if !group.runners.isEmpty { RunnerStrip(runners: group.runners) }
            ForEach(group.queued) { JobRow(job: $0) }
            ForEach(group.running) { JobRow(job: $0) }
            if group.queued.isEmpty && group.running.isEmpty {
                Text("Idle").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }
}

struct RunnerStrip: View {
    let runners: [Runner]

    var body: some View {
        let online = runners.filter(\.online)
        let busy = online.filter(\.busy)
        VStack(alignment: .leading, spacing: 4) {
            Text("Runners: \(busy.count) busy · \(online.count - busy.count) idle · \(runners.count - online.count) offline")
                .font(.caption).foregroundStyle(.secondary)
            FlowLayout(spacing: 4) {
                ForEach(runners) { r in
                    HStack(spacing: 3) {
                        Circle().fill(r.online ? (r.busy ? Color.blue : Color.green) : Color.gray).frame(width: 6, height: 6)
                        Text(r.name).font(.system(size: 10).monospaced())
                    }
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
            }
        }
    }
}

struct JobRow: View {
    let job: Job

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
                Image(systemName: job.isRunning ? "play.circle.fill" : "hourglass.circle.fill")
                    .foregroundStyle(job.isRunning ? Color.blue : Color.orange)
                    .font(.system(size: 15))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(job.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(timing).font(.caption.monospacedDigit())
                            .foregroundStyle(job.isRunning ? Color.blue : Color.orange)
                    }
                    Text(line2).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let l3 = line3 {
                        Text(l3).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    if let p = job.steps, job.isRunning {
                        HStack(spacing: 6) {
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.12))
                                Capsule().fill(Color.blue)
                                    .frame(width: 90 * CGFloat(p.done) / CGFloat(max(p.total, 1)))
                            }
                            .frame(width: 90, height: 4)
                            Text("step \(min(p.done + 1, p.total))/\(p.total)\(p.current.map { ": \(tidyStep($0))" } ?? "")")
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { if let u = job.url { NSWorkspace.shared.open(u) } }
        .help(job.labels.joined(separator: ", "))
    }

    private var timing: String {
        if job.isRunning, let s = job.startedAt { return "running \(shortDuration(Date().timeIntervalSince(s)))" }
        if let c = job.createdAt { return "\(job.status == "queued" ? "queued" : job.status) \(shortDuration(Date().timeIntervalSince(c)))" }
        return job.status
    }

    private var line2: String {
        var parts = [job.repoShort, job.workflow + (job.runNumber.map { " #\($0)" } ?? "")]
        if let a = job.runAttempt, a > 1 { parts.append("attempt \(a)") }
        if let b = job.branch { parts.append(b) }
        if let r = job.runnerName { parts.append("on \(r)") } else { parts.append("[\(job.labels.joined(separator: ", "))]") }
        return parts.joined(separator: " · ")
    }

    private var line3: String? {
        var parts: [String] = []
        if let a = job.actor { parts.append(a) }
        if let e = job.event { parts.append(e) }
        if let c = job.commitTitle { parts.append("“\(c)”") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Simple wrapping layout for runner pills.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 560
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
        return CGSize(width: width, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
    }
}

/// "Run actions/checkout@93cb6efe…" -> "Run actions/checkout@93cb6ef"
func tidyStep(_ s: String) -> String {
    s.replacingOccurrences(of: "@([0-9a-f]{7})[0-9a-f]{33}", with: "@$1", options: .regularExpression)
}
