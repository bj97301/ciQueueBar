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
    /// Hover card shown over the whole panel.
    @Published var hover: HoverInfo?
    /// Snapshot mode only: show the hover card for this bucket at this time.
    var pinnedHover: (bucket: Bucket, date: Date)?
    @Published var period: Period = Period(rawValue: UserDefaults.standard.string(forKey: "period") ?? "") ?? .h6 {
        didSet { UserDefaults.standard.set(period.rawValue, forKey: "period") }
    }
    let history = HistoryStore()

    func cpu(for runners: [Runner]) -> Double {
        runners.reduce(0) { $0 + (cpu[$1.name] ?? 0) }
    }
}

struct HoverInfo {
    let bucket: Bucket
    let bin: Bin
    let showDay: Bool
    /// Cursor position in the panel's coordinate space.
    let point: CGPoint
}

private struct CardHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
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
        .frame(width: 640)
        .coordinateSpace(name: "panel")
        .overlay(alignment: .topLeading) {
            GeometryReader { root in
                if let h = store.hover {
                    let w: CGFloat = 360
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
            Text("CI Queue").font(.headline)
            PeriodPicker(period: $store.period)
            Spacer()
            ForEach(visibleGroups) { g in
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
            } else if visibleGroups.isEmpty {
                Text("No queued or running jobs").foregroundStyle(.secondary)
            }
            ForEach(visibleGroups) { g in
                BucketSection(group: g, store: store,
                              bins: store.history.bins(bucket: g.bucket, period: store.period))
            }
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
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 14).padding(.vertical, 8)
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
                Label(group.bucket.rawValue, systemImage: group.bucket.symbol).font(.system(size: 13, weight: .bold))
                Spacer()
                if !group.runners.isEmpty && groupCPU > 0.05 {
                    Text("CPU \(cores(groupCPU)) cores").font(.caption.monospacedDigit()).foregroundStyle(.green)
                }
                Text("\(group.queued.count) queued · \(group.running.count) running")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if let w = group.longestWait {
                    Text("oldest wait \(shortDuration(w))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(w > 600 ? .red : .orange)
                }
            }
            HistoryChart(bins: bins, period: store.period, bucket: group.bucket, store: store)
            if !group.runners.isEmpty {
                RunnerCPUChart(points: store.history.runnerCPU(runners: group.runners.map(\.name), period: store.period),
                               period: store.period)
            }
            if !group.runners.isEmpty { RunnerStrip(runners: group.runners, cpu: store.cpu) }
            ForEach(group.queued) { JobRow(job: $0, cpu: nil) }
            ForEach(group.running) { JobRow(job: $0, cpu: $0.runnerName.flatMap { store.cpu[$0] }) }
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
    let cpu: [String: Double]

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
                        if let c = cpu[r.name], c >= 0.05 {
                            Text(cores(c)).font(.system(size: 10, weight: .semibold).monospacedDigit()).foregroundStyle(.green)
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
                    .font(.system(size: 15))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(job.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 6)
                        if let c = cpu {
                            Text("CPU \(cores(c))").font(.caption.monospacedDigit()).foregroundStyle(.green)
                                .help("CPU cores used by this job's processes")
                        }
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

struct PeriodPicker: View {
    @Binding var period: Period

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Period.allCases) { p in
                Text(p.rawValue)
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(p == period ? Color.accentColor.opacity(0.85) : .clear))
                    .foregroundStyle(p == period ? Color.white : Color.secondary)
                    .contentShape(Rectangle())
                    .onTapGesture { period = p }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.08)))
    }
}

/// Queued (orange area) and running (blue line) over the chosen period. Hover for the jobs at that moment.
struct HistoryChart: View {
    let bins: [Bin]
    let period: Period
    let bucket: Bucket
    @ObservedObject var store: Store

    private var domain: ClosedRange<Date> { Date().addingTimeInterval(-period.seconds)...Date() }
    private var hovered: Bin? { store.hover?.bucket == bucket ? store.hover?.bin : nil }

    var body: some View {
        if bins.isEmpty {
            Text("No history for this period yet").font(.caption2).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, minHeight: 30)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 10) {
                    legend(.orange, "queued", peak: bins.map(\.queued).max() ?? 0)
                    legend(.blue, "running", peak: bins.map(\.running).max() ?? 0)
                    Spacer()
                    Text("hover for jobs").foregroundStyle(.tertiary)
                }
                Chart {
                    ForEach(bins) { b in
                        AreaMark(x: .value("Time", b.date), y: .value("Queued", b.queued))
                            .foregroundStyle(Color.orange.opacity(0.45))
                            .interpolationMethod(.stepCenter)
                        LineMark(x: .value("Time", b.date), y: .value("Jobs", b.running), series: .value("s", "running"))
                            .foregroundStyle(Color.blue)
                            .interpolationMethod(.stepCenter)
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                    }
                    if let h = hovered {
                        RuleMark(x: .value("Time", h.date)).foregroundStyle(Color.primary.opacity(0.5))
                    }
                }
                .chartXScale(domain: domain)
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { AxisGridLine(); AxisValueLabel(format: axisFormat) } }
                .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { AxisGridLine(); AxisValueLabel() } }
                .chartOverlay { proxy in
                    GeometryReader { geo in
                        let origin = geo.frame(in: .named("panel")).origin
                        let plotX = proxy.plotFrame.map { geo[$0].origin.x } ?? 0
                        Rectangle().fill(Color.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let p):
                                    guard let d: Date = proxy.value(atX: p.x - plotX), let bin = nearest(d) else { return }
                                    store.hover = HoverInfo(bucket: bucket, bin: bin, showDay: period.seconds > 86400,
                                                            point: CGPoint(x: origin.x + p.x, y: origin.y + p.y))
                                case .ended:
                                    if store.hover?.bucket == bucket { store.hover = nil }
                                }
                            }
                            .onAppear {
                                // Snapshot mode: pin a hover card.
                                guard let pin = store.pinnedHover, pin.bucket == bucket, let bin = nearest(pin.date),
                                      let x = proxy.position(forX: pin.date) else { return }
                                store.hover = HoverInfo(bucket: bucket, bin: bin, showDay: period.seconds > 86400,
                                                        point: CGPoint(x: origin.x + plotX + x, y: origin.y + 30))
                            }
                    }
                }
                .frame(height: 70)
            }
            .font(.caption2)
        }
    }

    private func nearest(_ d: Date) -> Bin? {
        bins.min { abs($0.date.timeIntervalSince(d)) < abs($1.date.timeIntervalSince(d)) }
    }

    private var axisFormat: Date.FormatStyle {
        period.seconds > 86400 ? .dateTime.month(.abbreviated).day() : .dateTime.hour().minute()
    }

    private func legend(_ c: Color, _ name: String, peak: Double) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 8, height: 8)
            Text("\(name) · peak \(Int(peak))").foregroundStyle(.secondary)
        }
    }
}

/// Tooltip listing the queued and running jobs at the hovered moment, grouped by project and branch.
struct HoverCard: View {
    let info: HoverInfo
    private let maxJobs = 12

    var body: some View {
        let bin = info.bin
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(bin.date.formatted(info.showDay ? .dateTime.month(.abbreviated).day().hour().minute() : .dateTime.hour().minute()))
                    .font(.system(size: 11, weight: .bold))
                Spacer()
                Text(info.bucket.rawValue).foregroundStyle(.secondary)
            }
            if let j = bin.jobs {
                section("\(j.q.count) queued", .orange, j.q, limit: maxJobs)
                section("\(j.run.count) running", .blue, j.run, limit: max(3, maxJobs - j.q.count))
                if j.q.isEmpty && j.run.isEmpty { Text("Nothing queued or running").foregroundStyle(.secondary) }
            } else {
                Text("\(Int(bin.queued)) queued · \(Int(bin.running)) running").foregroundStyle(.secondary)
                Text("Job details weren't recorded for this time").foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 10))
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .windowBackgroundColor)).shadow(color: .black.opacity(0.5), radius: 8))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.18)))
    }

    @ViewBuilder private func section(_ title: String, _ color: Color, _ refs: [JobRef], limit: Int) -> some View {
        if !refs.isEmpty {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(color).padding(.top, 3)
            let shown = Array(refs.prefix(limit))
            // project · branch, then each workflow / job under it
            let groups = Dictionary(grouping: shown) { "\($0.r) · \($0.br ?? "?")" }
            let order = shown.map { "\($0.r) · \($0.br ?? "?")" }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            ForEach(order, id: \.self) { key in
                VStack(alignment: .leading, spacing: 0) {
                    Text(key).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
                    ForEach(Array((groups[key] ?? []).enumerated()), id: \.offset) { _, r in
                        Text("\(r.w) / \(r.n)").foregroundStyle(.secondary).lineLimit(1).padding(.leading, 8)
                    }
                }
            }
            if refs.count > shown.count { Text("+\(refs.count - shown.count) more").foregroundStyle(.tertiary) }
        }
    }
}

/// Stacked CPU cores per runner (agent) over the period.
struct RunnerCPUChart: View {
    let points: [RunnerCPUPoint]
    let period: Period

    var body: some View {
        if Set(points.map(\.date)).count >= 2 {
            let peak = Dictionary(grouping: points, by: \.date).values.map { $0.reduce(0) { $0 + $1.cores } }.max() ?? 0
            VStack(alignment: .leading, spacing: 2) {
                Text("CPU cores per runner · peak total \(cores(peak))").font(.caption2).foregroundStyle(.secondary)
                Chart(points) { p in
                    AreaMark(x: .value("Time", p.date), y: .value("Cores", p.cores), stacking: .standard)
                        .foregroundStyle(by: .value("Runner", p.label))
                        .interpolationMethod(.monotone)
                }
                .chartXScale(domain: Date().addingTimeInterval(-period.seconds)...Date())
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { AxisGridLine(); AxisValueLabel(format: period.seconds > 86400 ? .dateTime.month(.abbreviated).day() : .dateTime.hour().minute()) } }
                .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { AxisGridLine(); AxisValueLabel() } }
                .chartLegend(position: .bottom, alignment: .leading, spacing: 4)
                .frame(height: 110)
            }
            .font(.caption2)
        } else {
            Text("CPU per runner: collecting (one point per minute)").font(.caption2).foregroundStyle(.tertiary)
        }
    }
}
