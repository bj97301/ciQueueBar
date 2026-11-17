import Foundation

/// One point in time: per bucket key -> [queued, running, cpuCores] (cpu -1 when unknown).
struct Sample: Codable {
    let t: Double
    let b: [String: [Double]]
    /// Mean CPU cores per runner since the previous sample (runners under 0.05 omitted).
    var c: [String: Double]? = nil
    /// Per bucket key: which jobs were queued / running.
    var j: [String: JobRefs]? = nil
    /// Mean CPU per running job since the previous sample.
    var u: [JobCPU]? = nil
}

struct JobCPU: Codable {
    let r: String       // repo (short)
    let br: String?     // branch
    let w: String       // workflow
    let n: String       // job
    let rn: String      // runner
    let c: Double       // cores

    var text: String { "\(r) · \(br ?? "?") · \(w) / \(n)" }
}

enum CPUGroup: String, CaseIterable, Identifiable {
    case repo = "Repo", branch = "Branch", workflow = "Workflow", job = "Job"
    var id: String { rawValue }
    var plural: String { self == .branch ? "branches" : rawValue.lowercased() + "s" }

    func key(r: String, br: String?, w: String, n: String) -> String {
        switch self {
        case .repo: return r
        case .branch: return "\(r) · \(br ?? "?")"
        case .workflow: return "\(r) · \(w)"
        case .job: return "\(r) · \(br ?? "?") · \(w) / \(n)"
        }
    }
    func key(_ j: JobCPU) -> String { key(r: j.r, br: j.br, w: j.w, n: j.n) }
}

struct GroupUsage: Identifiable {
    var id: String { name }
    let name: String
    let coreHours: Double
    let peak: Double
}

struct JobRef: Codable, Hashable {
    let r: String       // repo (short)
    let br: String?     // branch
    let w: String       // workflow
    let n: String       // job

    var text: String { [r, br, "\(w) / \(n)"].compactMap { $0 }.joined(separator: " · ") }
}

struct JobRefs: Codable {
    var q: [JobRef] = []
    var run: [JobRef] = []
}

struct RunnerCPUPoint: Identifiable {
    var id: String { runner + "\(date.timeIntervalSince1970)" }
    let date: Date
    let runner: String
    let label: String
    let cores: Double
    /// What the runner was doing (job) at that time, when known.
    var detail: String? = nil
}

enum Period: String, CaseIterable, Identifiable {
    case h1 = "1H", h6 = "6H", d1 = "1D", d7 = "7D", d30 = "30D"
    var id: String { rawValue }
    var seconds: TimeInterval {
        switch self {
        case .h1: return 3600
        case .h6: return 6 * 3600
        case .d1: return 86400
        case .d7: return 7 * 86400
        case .d30: return 30 * 86400
        }
    }
}

struct Bin: Identifiable {
    var id: Date { date }
    let date: Date
    let queued: Double
    let running: Double
    let cpu: Double?
    /// Jobs at the busiest moment in the bin; nil when not recorded.
    let jobs: JobRefs?
}

/// Append-only JSON-lines history, kept for 30 days.
final class HistoryStore {
    private(set) var samples: [Sample] = []
    private let url: URL
    private let keep: TimeInterval = 31 * 86400

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CIQueueBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("history.jsonl")
        load()
    }

    var isEmpty: Bool { samples.isEmpty }

    private func load() {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let dec = JSONDecoder()
        let cutoff = Date().timeIntervalSince1970 - keep
        let all = text.split(separator: "\n").compactMap { try? dec.decode(Sample.self, from: Data($0.utf8)) }
        samples = all.filter { $0.t >= cutoff }.sorted { $0.t < $1.t }
        if samples.count != all.count { rewrite() }   // prune old lines only when needed
    }

    func append(_ s: Sample) {
        samples.append(s)
        guard let line = try? JSONEncoder().encode(s) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(line + Data("\n".utf8))
            try? h.close()
        } else {
            try? (line + Data("\n".utf8)).write(to: url)
        }
    }

    /// Adds reconstructed samples older than anything recorded.
    func merge(_ older: [Sample]) {
        let first = samples.first?.t ?? .infinity
        samples = (older.filter { $0.t < first } + samples).sorted { $0.t < $1.t }
        rewrite()
    }

    private func rewrite() {
        let enc = JSONEncoder()
        let data = samples.compactMap { try? enc.encode($0) }.reduce(into: Data()) { $0 += $1 + Data("\n".utf8) }
        try? data.write(to: url, options: .atomic)
    }

    /// Mean CPU per runner per bin, zero-filled so stacked areas line up. Only runners that used CPU are included.
    func runnerCPU(runners: [String], period: Period, count: Int = 120, now: Date = Date()) -> [RunnerCPUPoint] {
        let end = now.timeIntervalSince1970, start = end - period.seconds
        let width = period.seconds / Double(count)
        var n = [Int](repeating: 0, count: count)
        var sums: [String: [Double]] = [:]
        var jobs: [String: [String?]] = [:]
        let wanted = Set(runners)
        for s in samples where s.t >= start && s.t <= end {
            guard let c = s.c else { continue }
            let i = min(count - 1, Int((s.t - start) / width))
            n[i] += 1
            for (r, v) in c where wanted.contains(r) { sums[r, default: [Double](repeating: 0, count: count)][i] += v }
            for u in s.u ?? [] where wanted.contains(u.rn) { jobs[u.rn, default: [String?](repeating: nil, count: count)][i] = u.text }
        }
        let active = sums.filter { $0.value.contains { $0 > 0 } }.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let labels = shortLabels(active)
        var out: [RunnerCPUPoint] = []
        for i in 0..<count where n[i] > 0 {
            let d = Date(timeIntervalSince1970: start + (Double(i) + 0.5) * width)
            for r in active {
                out.append(RunnerCPUPoint(date: d, runner: r, label: labels[r] ?? r, cores: sums[r]![i] / Double(n[i]),
                                          detail: jobs[r]?[i] ?? nil))
            }
        }
        return out
    }

    /// CPU per repo / branch / workflow / job: stacked points for the top groups and a ranking by core-hours.
    func cpuByGroup(_ group: CPUGroup, period: Period, count: Int = 120, top: Int = 8, now: Date = Date())
        -> (points: [RunnerCPUPoint], ranking: [GroupUsage]) {
        let end = now.timeIntervalSince1970, start = end - period.seconds
        let width = period.seconds / Double(count)
        let inRange = samples.filter { $0.t >= start && $0.t <= end && $0.c != nil }
        var n = [Int](repeating: 0, count: count)
        var sums: [String: [Double]] = [:]
        var totals: [String: Double] = [:], peaks: [String: Double] = [:]
        for (k, s) in inRange.enumerated() {
            let i = min(count - 1, Int((s.t - start) / width))
            n[i] += 1
            // Each sample covers the time until the next one (capped at 5 minutes).
            let dt = k + 1 < inRange.count ? min(300, inRange[k + 1].t - s.t) : 60
            var perKey: [String: Double] = [:]
            for u in s.u ?? [] { perKey[group.key(u), default: 0] += u.c }
            for (key, c) in perKey {
                sums[key, default: [Double](repeating: 0, count: count)][i] += c
                totals[key, default: 0] += c * dt / 3600
                peaks[key] = max(peaks[key] ?? 0, c)
            }
        }
        let ranked = totals.sorted { $0.value > $1.value }
        let topKeys = ranked.prefix(top).map(\.key)
        let ranking = ranked.prefix(12).map { GroupUsage(name: $0.key, coreHours: $0.value, peak: peaks[$0.key] ?? 0) }
        var out: [RunnerCPUPoint] = []
        for i in 0..<count where n[i] > 0 {
            let d = Date(timeIntervalSince1970: start + (Double(i) + 0.5) * width)
            var other = 0.0
            for (key, v) in sums where !topKeys.contains(key) { other += v[i] }
            for key in topKeys { out.append(RunnerCPUPoint(date: d, runner: key, label: key, cores: (sums[key]?[i] ?? 0) / Double(n[i]))) }
            if sums.count > topKeys.count { out.append(RunnerCPUPoint(date: d, runner: "other", label: "other", cores: other / Double(n[i]))) }
        }
        return (out, ranking)
    }

    /// Up to `count` bins covering the period. Peak queued/running per bin, mean CPU.
    func bins(bucket: Bucket, period: Period, count: Int = 120, now: Date = Date()) -> [Bin] {
        let end = now.timeIntervalSince1970, start = end - period.seconds
        let width = period.seconds / Double(count)
        var q = [Double](repeating: -1, count: count), r = q
        var cpuSum = [Double](repeating: 0, count: count), cpuN = [Int](repeating: 0, count: count)
        var jobs = [JobRefs?](repeating: nil, count: count), busiest = [Double](repeating: -1, count: count)
        for s in samples where s.t >= start && s.t <= end {
            guard let v = s.b[bucket.key], v.count >= 2 else { continue }
            let i = min(count - 1, Int((s.t - start) / width))
            q[i] = max(q[i], v[0]); r[i] = max(r[i], v[1])
            if let j = s.j, v[0] * 1000 + v[1] > busiest[i] {
                busiest[i] = v[0] * 1000 + v[1]
                jobs[i] = j[bucket.key] ?? JobRefs()
            }
            if v.count > 2, v[2] >= 0 { cpuSum[i] += v[2]; cpuN[i] += 1 }
        }
        return (0..<count).compactMap { i in
            guard q[i] >= 0 else { return nil }
            return Bin(date: Date(timeIntervalSince1970: start + (Double(i) + 0.5) * width),
                       queued: q[i], running: r[i], cpu: cpuN[i] > 0 ? cpuSum[i] / Double(cpuN[i]) : nil, jobs: jobs[i])
        }
    }
}

/// Drops the shared prefix so "bryan-m1-ultra-02" / "bryan-m1-ultra-08" read as "02" / "08".
func shortLabels(_ names: [String]) -> [String: String] {
    guard names.count > 1, var prefix = names.first else { return Dictionary(uniqueKeysWithValues: names.map { ($0, $0) }) }
    for n in names.dropFirst() { while !n.hasPrefix(prefix) { prefix.removeLast() } }
    if let cut = prefix.lastIndex(where: { $0 == "-" || $0 == "_" }) { prefix = String(prefix[...cut]) } else { prefix = "" }
    return Dictionary(uniqueKeysWithValues: names.map { n in
        let short = String(n.dropFirst(prefix.count))
        return (n, short.isEmpty ? n : short)
    })
}
