import SwiftUI
import Charts

final class Store: ObservableObject {
    @Published var snapshot = Snapshot()
    @Published var error: String?
    @Published var updated: Date?
    @Published var refreshing = false
    /// Runner name -> CPU cores in use.
    @Published var cpu: [String: Double] = [:]
    /// Bumped whenever history changes so charts redraw.
    @Published var historyVersion = 0
    @Published var maxHeight: CGFloat = 900
    /// Section columns (2 when the screen is wide enough; config "columns" overrides).
    @Published var columns = 2
    /// Hover card shown over the whole panel.
    @Published var hover: HoverInfo?
    /// Snapshot mode only: show the hover card for this chart id at this time.
    var pinnedHover: (chart: String, date: Date)?
    @Published var cpuGroup: CPUGroup = CPUGroup(rawValue: UserDefaults.standard.string(forKey: "cpuGroup") ?? "") ?? .repo {
        didSet { if persist { UserDefaults.standard.set(cpuGroup.rawValue, forKey: "cpuGroup") } }
    }
    @Published var period: Period = Period(rawValue: UserDefaults.standard.string(forKey: "period") ?? "") ?? .h6 {
        didSet { if persist { UserDefaults.standard.set(period.rawValue, forKey: "period") } }
    }
    let history = HistoryStore()
    /// Snapshot mode turns this off so its settings don't change the app's.
    var persist = true

    func cpu(for runners: [Runner]) -> Double {
        runners.reduce(0) { $0 + (cpu[$1.name] ?? 0) }
    }
}

private struct CardHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Text and layout scale (config "textScale", default 1.5).
var UIScale: CGFloat = 1.5

extension Font {
    /// System font scaled by UIScale.
    static func s(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size * UIScale, weight: weight) }
}

func cores(_ c: Double) -> String { c < 10 ? String(format: "%.1f", c) : String(format: "%.0f", c) }

struct PanelView: View {
    @ObservedObject var store: Store
    var scrolls = true
    var onRefresh: () -> Void = {}
    var onConfig: () -> Void = {}
    var onQuit: () -> Void = {}
    @State private var contentHeight: CGFloat = 200
    @State private var cardHeight: CGFloat = 200

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if scrolls {
                // Grow to fit; only scroll when taller than the screen allows.
                ScrollView {
                    content.background(GeometryReader { Color.clear.preference(key: HeightKey.self, value: $0.size.height) })
                }
                .frame(height: min(contentHeight, store.maxHeight))
                .onPreferenceChange(HeightKey.self) { contentHeight = $0 }
            } else {
                content
            }
            Divider()
            footer
        }
        .frame(width: columnWidth * CGFloat(store.columns) + 7 * UIScale * CGFloat(store.columns - 1) + 14 * UIScale)
        .coordinateSpace(name: "panel")
        .overlay(alignment: .topLeading) {
            GeometryReader { root in
                if let h = store.hover {
                    let w: CGFloat = 360 * UIScale
                    let x = h.point.x + w + 16 > root.size.width ? max(4, h.point.x - w - 12) : h.point.x + 14
                    let y = min(max(4, h.point.y + 12), max(4, root.size.height - cardHeight - 4))
                    HoverCard(info: h)
                        .frame(width: w, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .background(GeometryReader { Color.clear.preference(key: CardHeightKey.self, value: $0.size.height) })
                        .offset(x: x, y: y)
                        .allowsHitTesting(false)
                }
            }
        }
        .onPreferenceChange(CardHeightKey.self) { cardHeight = $0 }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("CI Queue").font(.s(14, .bold))
            Segmented(value: $store.period)
            Spacer()
            ForEach(visibleGroups) { g in
                HStack(spacing: 4) {
                    Image(systemName: g.bucket.symbol)
                    Text("\(g.queued.count)").foregroundStyle(g.queued.isEmpty ? Color.secondary : Color.orange)
                    Text("/")
                        .foregroundStyle(.tertiary)
                    Text("\(g.running.count)").foregroundStyle(g.running.isEmpty ? Color.secondary : Color.blue)
                }
                .font(.s(11, .semibold).monospacedDigit())
                .help("\(g.bucket.rawValue): queued / running")
            }
        }
        .padding(.horizontal, 7 * UIScale).padding(.vertical, 5 * UIScale)
    }

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 7 * UIScale) {
            if let e = store.error {
                Label(e, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.s(12))
            }
            if store.updated == nil {
                HStack { ProgressView().controlSize(.small); Text("Loading…").foregroundStyle(.secondary) }
            } else if visibleGroups.isEmpty {
                Text("No queued or running jobs").foregroundStyle(.secondary)
            }
            MasonryLayout(columns: store.columns, spacing: 7 * UIScale) {
                if !store.snapshot.runners.isEmpty { CPUSection(store: store) }
                ForEach(visibleGroups) { g in
                    BucketSection(group: g, store: store,
                                  bins: store.history.bins(bucket: g.bucket, period: store.period))
                }
            }
        }
        .padding(7 * UIScale)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func iconButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Image(systemName: symbol)
            .font(.s(12))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .help(help)
    }

    /// Live groups plus any runner type that had jobs during the chosen period.
    private var visibleGroups: [BucketGroup] {
        let live = store.snapshot.groups
        return Bucket.allCases.compactMap { b in
            if let g = live.first(where: { $0.bucket == b }) { return g }
            let busy = store.history.bins(bucket: b, period: store.period).contains { $0.queued > 0 || $0.running > 0 }
            return busy ? BucketGroup(bucket: b, queued: [], running: [], runners: []) : nil
        }
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
        .font(.s(11)).foregroundStyle(.secondary)
        .padding(.horizontal, 7 * UIScale).padding(.vertical, 4 * UIScale)
    }
}

struct BucketSection: View {
    let group: BucketGroup
    @ObservedObject var store: Store
    let bins: [Bin]

    var body: some View {
        let groupCPU = store.cpu(for: group.runners)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(group.bucket.rawValue, systemImage: group.bucket.symbol).font(.s(13, .bold))
                Spacer()
                if !group.runners.isEmpty && groupCPU > 0.05 {
                    Text("CPU \(cores(groupCPU)) cores").font(.s(11).monospacedDigit()).foregroundStyle(.green)
                }
                Text("\(group.queued.count) queued · \(group.running.count) running")
                    .font(.s(11).monospacedDigit()).foregroundStyle(.secondary)
                if let w = group.longestWait {
                    Text("oldest wait \(shortDuration(w))")
                        .font(.s(11).monospacedDigit())
                        .foregroundStyle(w > 600 ? .red : .orange)
                }
            }
            HistoryChart(bins: bins, period: store.period, bucket: group.bucket, store: store)
            if !group.runners.isEmpty {
                StackedCPUChart(id: "cpu-\(group.bucket.key)", title: "CPU cores per runner",
                                points: store.history.runnerCPU(runners: group.runners.map(\.name), period: store.period),
                                period: store.period, store: store)
            }
            if !group.runners.isEmpty { RunnerStrip(runners: group.runners, cpu: store.cpu) }
            ForEach(group.queued) { JobRow(job: $0, cpu: nil) }
            ForEach(group.running) { JobRow(job: $0, cpu: $0.runnerName.flatMap { store.cpu[$0] }) }
            if group.queued.isEmpty && group.running.isEmpty {
                Text("Idle").font(.s(11)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(5 * UIScale)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }
}

struct RunnerStrip: View {
    let runners: [Runner]
    let cpu: [String: Double]

    var body: some View {
        let online = runners.filter(\.online)
        let busy = online.filter(\.busy)
        VStack(alignment: .leading, spacing: 4) {
            Text("Runners: \(busy.count) busy · \(online.count - busy.count) idle · \(runners.count - online.count) offline")
                .font(.s(11)).foregroundStyle(.secondary)
            FlowLayout(spacing: 4) {
                ForEach(runners) { r in
                    HStack(spacing: 3) {
                        Circle().fill(r.online ? (r.busy ? Color.blue : Color.green) : Color.gray).frame(width: 6 * UIScale, height: 6 * UIScale)
                        Text(r.name).font(.s(10).monospaced())
                        if let c = cpu[r.name], c >= 0.05 {
                            Text(cores(c)).font(.s(10, .semibold).monospacedDigit()).foregroundStyle(.green)
                        }
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
    let cpu: Double?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
                Image(systemName: job.isRunning ? "play.circle.fill" : "hourglass.circle.fill")
                    .foregroundStyle(job.isRunning ? Color.blue : Color.orange)
                    .font(.s(15))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(job.name).font(.s(12, .semibold)).lineLimit(1)
                        Spacer(minLength: 6)
                        if let c = cpu {
                            Text("CPU \(cores(c))").font(.s(11).monospacedDigit()).foregroundStyle(.green)
                                .help("CPU cores used by this job's processes")
                        }
                        Text(timing).font(.s(11).monospacedDigit())
                            .foregroundStyle(job.isRunning ? Color.blue : Color.orange)
                    }
                    Text(line2).font(.s(11)).foregroundStyle(.secondary).lineLimit(1)
                    if let l3 = line3 {
                        Text(l3).font(.s(11)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    if let t = job.t3 { T3Button(link: t) }
                    if let p = job.steps, job.isRunning {
                        HStack(spacing: 6) {
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.12))
                                Capsule().fill(Color.blue)
                                    .frame(width: 90 * UIScale * CGFloat(p.done) / CGFloat(max(p.total, 1)))
                            }
                            .frame(width: 90 * UIScale, height: 4 * UIScale)
                            Text("step \(min(p.done + 1, p.total))/\(p.total)\(p.current.map { ": \(tidyStep($0))" } ?? "")")
                                .font(.s(10)).foregroundStyle(.secondary).lineLimit(1)
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

/// "T3 thread title" link; clicking opens the thread in T3 Code.
struct T3Button: View {
    let link: T3Link

    var body: some View {
        HStack(spacing: 3 * UIScale) {
            Image(systemName: "bubble.left.and.text.bubble.right.fill")
            Text("T3: \(link.title)").lineLimit(1).truncationMode(.tail)
            Text("· \(link.via)").foregroundStyle(.secondary)
        }
        .font(.s(11, .medium))
        .foregroundStyle(Color.purple)
        .contentShape(Rectangle())
        .onTapGesture { NSWorkspace.shared.open(link.url) }
        .help("Open this T3 Code thread")
    }
}

/// Width of one section column.
let columnWidth: CGFloat = 540 * UIScale

/// Places each section in the currently shorter column, keeping columns balanced.
struct MasonryLayout: Layout {
    var columns: Int
    var spacing: CGFloat

    private func arrange(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], height: CGFloat) {
        let n = max(1, columns)
        let colW = (width - spacing * CGFloat(n - 1)) / CGFloat(n)
        var heights = [CGFloat](repeating: 0, count: n)
        var frames: [CGRect] = []
        for v in subviews {
            let h = v.sizeThatFits(ProposedViewSize(width: colW, height: nil)).height
            let c = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            frames.append(CGRect(x: CGFloat(c) * (colW + spacing), y: heights[c], width: colW, height: h))
            heights[c] += h + spacing
        }
        return (frames, max(0, (heights.max() ?? 0) - spacing))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? columnWidth * CGFloat(columns)
        return CGSize(width: width, height: arrange(width: width, subviews: subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(width: bounds.width, subviews: subviews).frames
        for (v, f) in zip(subviews, frames) {
            v.place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY),
                    proposal: ProposedViewSize(width: f.width, height: f.height))
        }
    }
}

/// Simple wrapping layout for runner pills.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 560 * UIScale
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

/// Small segmented control drawn with plain views (renders in snapshots too).
struct Segmented<T: Hashable & Identifiable & CaseIterable & RawRepresentable>: View where T.RawValue == String, T.AllCases: RandomAccessCollection {
    @Binding var value: T

    var body: some View {
        HStack(spacing: 0) {
            ForEach(T.allCases) { p in
                Text(p.rawValue)
                    .font(.s(10, .semibold))
                    .padding(.horizontal, 4 * UIScale).padding(.vertical, 1.5 * UIScale)
                    .background(RoundedRectangle(cornerRadius: 5).fill(p == value ? Color.accentColor.opacity(0.85) : .clear))
                    .foregroundStyle(p == value ? Color.white : Color.secondary)
                    .contentShape(Rectangle())
                    .onTapGesture { value = p }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.08)))
    }
}
