import SwiftUI
import Charts

// MARK: - Hover model

struct HoverRow: Identifiable {
    let id = UUID()
    let color: Color
    let label: String
    let value: String
    var detail: String? = nil
}

enum HoverContent {
    /// Queue chart: queued / running jobs at that moment.
    case queue(Bin, Bucket)
    /// Any series chart: one row per series.
    case rows(title: String, rows: [HoverRow], footer: String?)
}

struct HoverInfo {
    let chart: String
    let date: Date
    let showDay: Bool
    /// Cursor position in the panel's coordinate space.
    let point: CGPoint
    let content: HoverContent
}

let seriesPalette: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .yellow, .red, .mint, .indigo, .brown, .cyan]

func axisFormat(_ period: Period) -> Date.FormatStyle {
    period.seconds > 86400 ? .dateTime.month(.abbreviated).day() : .dateTime.hour().minute()
}

/// Transparent layer over a chart's plot that tracks the cursor and publishes a hover card.
struct ChartHoverLayer: View {
    let proxy: ChartProxy
    let chart: String
    let period: Period
    @ObservedObject var store: Store
    /// Snap a cursor time to the nearest data time.
    let snap: (Date) -> Date?
    let content: (Date) -> HoverContent?

    var body: some View {
        GeometryReader { geo in
            let origin = geo.frame(in: .named("panel")).origin
            let plotX = proxy.plotFrame.map { geo[$0].origin.x } ?? 0
            Rectangle().fill(Color.clear).contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p):
                        guard let d: Date = proxy.value(atX: p.x - plotX), let t = snap(d), let c = content(t) else { return }
                        store.hover = HoverInfo(chart: chart, date: t, showDay: period.seconds > 86400,
                                                point: CGPoint(x: origin.x + p.x, y: origin.y + p.y), content: c)
                    case .ended:
                        if store.hover?.chart == chart { store.hover = nil }
                    }
                }
                .onAppear {
                    // Snapshot mode: pin a hover card.
                    guard let pin = store.pinnedHover, pin.chart == chart, let t = snap(pin.date), let c = content(t),
                          let x = proxy.position(forX: t) else { return }
                    store.hover = HoverInfo(chart: chart, date: t, showDay: period.seconds > 86400,
                                            point: CGPoint(x: origin.x + plotX + x, y: origin.y + 20 * UIScale), content: c)
                }
        }
    }
}

func nearestDate(_ dates: [Date], _ d: Date) -> Date? {
    dates.min { abs($0.timeIntervalSince(d)) < abs($1.timeIntervalSince(d)) }
}

// MARK: - Hover card

struct HoverCard: View {
    let info: HoverInfo
    private let maxJobs = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            switch info.content {
            case .queue(let bin, let bucket):
                header(bucket.rawValue)
                queue(bin)
            case .rows(let title, let rows, let footer):
                header(title)
                if rows.isEmpty { Text("Nothing").foregroundStyle(.secondary) }
                ForEach(rows) { r in
                    HStack(alignment: .firstTextBaseline, spacing: 4 * UIScale) {
                        Circle().fill(r.color).frame(width: 5 * UIScale, height: 5 * UIScale)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(r.label).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
                            if let d = r.detail { Text(d).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                        }
                        Spacer(minLength: 4)
                        Text(r.value).fontWeight(.semibold).monospacedDigit()
                    }
                }
                if let footer { Text(footer).foregroundStyle(.secondary).padding(.top, 2) }
            }
        }
        .font(.s(10))
        .padding(4 * UIScale)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .windowBackgroundColor)).shadow(color: .black.opacity(0.5), radius: 8))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.18)))
    }

    private func header(_ title: String) -> some View {
        HStack {
            Text(info.date.formatted(info.showDay ? .dateTime.month(.abbreviated).day().hour().minute() : .dateTime.hour().minute()))
                .font(.s(11, .bold))
            Spacer()
            Text(title).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func queue(_ bin: Bin) -> some View {
        if let j = bin.jobs {
            jobs("\(j.q.count) queued", .orange, j.q, limit: maxJobs)
            jobs("\(j.run.count) running", .blue, j.run, limit: max(3, maxJobs - j.q.count))
            if j.q.isEmpty && j.run.isEmpty { Text("Nothing queued or running").foregroundStyle(.secondary) }
        } else {
            Text("\(Int(bin.queued)) queued · \(Int(bin.running)) running").foregroundStyle(.secondary)
            Text("Job details weren't recorded for this time").foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private func jobs(_ title: String, _ color: Color, _ refs: [JobRef], limit: Int) -> some View {
        if !refs.isEmpty {
            Text(title).font(.s(10, .semibold)).foregroundStyle(color).padding(.top, 3)
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

// MARK: - Queue chart

/// Queued (orange area) and running (blue line) over the chosen period. Hover for the jobs at that moment.
struct HistoryChart: View {
    let bins: [Bin]
    let period: Period
    let bucket: Bucket
    @ObservedObject var store: Store

    private var id: String { "queue-\(bucket.key)" }
    private var domain: ClosedRange<Date> { Date().addingTimeInterval(-period.seconds)...Date() }

    var body: some View {
        if bins.isEmpty {
            Text("No history for this period yet").font(.s(10)).foregroundStyle(.tertiary)
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
                    if let h = store.hover, h.chart == id {
                        RuleMark(x: .value("Time", h.date)).foregroundStyle(Color.primary.opacity(0.5))
                    }
                }
                .chartXScale(domain: domain)
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { AxisGridLine(); AxisValueLabel(format: axisFormat(period)).font(.s(10)) } }
                .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { AxisGridLine(); AxisValueLabel().font(.s(10)) } }
                .chartOverlay { proxy in
                    ChartHoverLayer(proxy: proxy, chart: id, period: period, store: store,
                                    snap: { nearestDate(bins.map(\.date), $0) },
                                    content: { t in bins.first { $0.date == t }.map { .queue($0, bucket) } })
                }
                .frame(height: 70 * UIScale)
            }
            .font(.s(10))
        }
    }

    private func legend(_ c: Color, _ name: String, peak: Double) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 8 * UIScale, height: 8 * UIScale)
            Text("\(name) · peak \(Int(peak))").foregroundStyle(.secondary)
        }
    }
}

// MARK: - Stacked CPU chart

/// Stacked CPU cores per series (runner, repo, branch…) over the period. Hover lists each series at that moment.
struct StackedCPUChart: View {
    let id: String
    let title: String
    let points: [RunnerCPUPoint]
    let period: Period
    @ObservedObject var store: Store

    private var labels: [String] { points.map(\.label).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } } }
    private func color(_ label: String) -> Color {
        label == "other" ? .gray : seriesPalette[(labels.firstIndex(of: label) ?? 0) % seriesPalette.count]
    }

    var body: some View {
        let dates = Array(Set(points.map(\.date))).sorted()
        if dates.count >= 2 {
            let byDate = Dictionary(grouping: points, by: \.date)
            let peak = byDate.values.map { $0.reduce(0) { $0 + $1.cores } }.max() ?? 0
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("\(title) · peak total \(cores(peak))").foregroundStyle(.secondary)
                    Spacer()
                    Text("hover for details").foregroundStyle(.tertiary)
                }
                Chart {
                    ForEach(points) { p in
                        AreaMark(x: .value("Time", p.date), y: .value("Cores", p.cores), stacking: .standard)
                            .foregroundStyle(by: .value("Series", p.label))
                            .interpolationMethod(.monotone)
                    }
                    if let h = store.hover, h.chart == id {
                        RuleMark(x: .value("Time", h.date)).foregroundStyle(Color.primary.opacity(0.5))
                    }
                }
                .chartForegroundStyleScale(domain: labels, range: labels.map(color))
                .chartLegend(.hidden)
                .chartXScale(domain: Date().addingTimeInterval(-period.seconds)...Date())
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { AxisGridLine(); AxisValueLabel(format: axisFormat(period)).font(.s(10)) } }
                .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { AxisGridLine(); AxisValueLabel().font(.s(10)) } }
                .chartOverlay { proxy in
                    ChartHoverLayer(proxy: proxy, chart: id, period: period, store: store,
                                    snap: { nearestDate(dates, $0) },
                                    content: { t in
                                        let at = (byDate[t] ?? []).filter { $0.cores >= 0.01 }.sorted { $0.cores > $1.cores }
                                        let total = at.reduce(0) { $0 + $1.cores }
                                        return .rows(title: title,
                                                     rows: at.map { HoverRow(color: color($0.label), label: $0.runner,
                                                                             value: cores($0.cores), detail: $0.detail) },
                                                     footer: at.isEmpty ? "No CPU recorded" : "Total \(cores(total)) cores")
                                    })
                }
                .frame(height: 100 * UIScale)
                FlowLayout(spacing: 4 * UIScale) {
                    ForEach(labels, id: \.self) { l in
                        HStack(spacing: 2 * UIScale) {
                            Circle().fill(color(l)).frame(width: 6 * UIScale, height: 6 * UIScale)
                            Text(l).lineLimit(1)
                        }
                    }
                }
            }
            .font(.s(10))
        } else {
            Text("\(title): collecting (one point per minute)").font(.s(10)).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - CPU section

/// What's using CPU: live jobs ranked by cores, plus history and a ranking by repo / branch / workflow / job.
struct CPUSection: View {
    @ObservedObject var store: Store

    var body: some View {
        let running = store.snapshot.jobs.filter(\.isRunning)
            .compactMap { j -> (Job, Double)? in j.runnerName.flatMap { store.cpu[$0] }.map { (j, $0) } }
            .sorted { $0.1 > $1.1 }
        let total = store.cpu.values.reduce(0, +)
        let maxNow = max(running.first?.1 ?? 1, 0.1)
        let byGroup = store.history.cpuByGroup(store.cpuGroup, period: store.period)
        let maxCH = max(byGroup.ranking.first?.coreHours ?? 1, 0.001)

        VStack(alignment: .leading, spacing: 4 * UIScale) {
            HStack(alignment: .firstTextBaseline) {
                Label("CPU", systemImage: "cpu").font(.s(13, .bold))
                Text("by").foregroundStyle(.secondary)
                Segmented(value: $store.cpuGroup)
                Spacer()
                Text("now \(cores(total)) cores on self-hosted runners").font(.s(11).monospacedDigit()).foregroundStyle(.green)
            }
            .font(.s(11))

            Text("Right now").font(.s(11, .semibold)).foregroundStyle(.secondary)
            if running.isEmpty {
                Text("No running jobs on self-hosted runners").font(.s(11)).foregroundStyle(.tertiary)
            }
            ForEach(running.prefix(6), id: \.0.id) { j, c in
                HStack(spacing: 5 * UIScale) {
                    bar(c / maxNow, .green).frame(width: 60 * UIScale)
                    Text(cores(c)).font(.s(12, .bold).monospacedDigit()).foregroundStyle(.green).frame(width: 28 * UIScale, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(j.repoShort) · \(j.branch ?? "?")").font(.s(11, .semibold)).lineLimit(1)
                        Text("\(j.workflow) / \(j.name) · \(j.runnerName ?? "")").font(.s(10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture { if let u = j.url { NSWorkspace.shared.open(u) } }
            }

            StackedCPUChart(id: "cpu-group", title: "CPU cores by \(store.cpuGroup.rawValue.lowercased())",
                            points: byGroup.points, period: store.period, store: store)

            if !byGroup.ranking.isEmpty {
                Text("Top \(store.cpuGroup.plural), \(store.period.rawValue) (core-hours)")
                    .font(.s(11, .semibold)).foregroundStyle(.secondary).padding(.top, 2)
                ForEach(byGroup.ranking) { g in
                    HStack(spacing: 5 * UIScale) {
                        bar(g.coreHours / maxCH, .orange).frame(width: 60 * UIScale)
                        Text(String(format: g.coreHours < 10 ? "%.2f" : "%.0f", g.coreHours))
                            .font(.s(11, .bold).monospacedDigit()).frame(width: 34 * UIScale, alignment: .trailing)
                        Text(g.name).font(.s(11)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text("peak \(cores(g.peak))").font(.s(10).monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(5 * UIScale)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    private func bar(_ fraction: Double, _ color: Color) -> some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(color).frame(width: max(2, g.size.width * min(1, fraction)))
            }
        }
        .frame(height: 5 * UIScale)
    }
}
