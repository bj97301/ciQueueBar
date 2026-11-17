import Foundation

struct StepProgress: Hashable {
    let done: Int
    let total: Int
    let current: String?
}

struct Job: Hashable, Identifiable {
    let id: Int
    let repo: String
    let workflow: String
    let name: String
    let status: String          // queued | in_progress | waiting | pending
    let labels: [String]
    let url: URL?
    let createdAt: Date?
    let startedAt: Date?
    let runnerName: String?
    let runNumber: Int?
    let runAttempt: Int?
    let branch: String?
    let event: String?
    let actor: String?
    let commitTitle: String?
    let steps: StepProgress?
    /// PR numbers tied to the run: its pull_requests plus "Merge pull request #N" in the commit title.
    var prNumbers: [Int] = []
    /// T3 Code thread that most likely started it.
    var t3: T3Link? = nil

    var isRunning: Bool { status == "in_progress" }
    var repoShort: String { repo.split(separator: "/").last.map(String.init) ?? repo }
}

struct Runner: Hashable, Identifiable {
    var id: String { owner + "/" + name }
    let owner: String
    let name: String
    let os: String
    let online: Bool
    let busy: Bool
    let labels: [String]
}

enum Bucket: String, CaseIterable, Identifiable {
    case mac = "Mac (self-hosted)"
    case linux = "Linux (self-hosted)"
    case blacksmith = "Blacksmith"
    case github = "GitHub-hosted"
    case other = "Other"

    var id: String { rawValue }
    /// Stable key used in the history file.
    var key: String { String(describing: self) }

    var short: String {
        switch self {
        case .mac: return "Mac"
        case .linux: return "Lnx"
        case .blacksmith: return "BS"
        case .github: return "GH"
        case .other: return "?"
        }
    }

    var symbol: String {
        switch self {
        case .mac: return "desktopcomputer"
        case .linux: return "server.rack"
        case .blacksmith: return "hammer.fill"
        case .github: return "cloud.fill"
        case .other: return "questionmark.circle"
        }
    }

    static func forRunner(_ r: Runner) -> Bucket {
        let os = r.os.lowercased()
        if os.contains("mac") { return .mac }
        if os.contains("linux") { return .linux }
        return .other
    }

    /// Classify a job by its `runs-on` labels. Known self-hosted runners win, then label heuristics.
    static func classify(_ labels: [String], runners: [Runner]) -> Bucket {
        let l = labels.map { $0.lowercased() }
        if l.contains(where: { $0.hasPrefix("blacksmith") }) { return .blacksmith }
        let want = Set(l)
        if !want.isEmpty, let r = runners.first(where: { want.isSubset(of: Set($0.labels.map { $0.lowercased() })) }) {
            return forRunner(r)
        }
        if l.contains(where: { $0.hasPrefix("ubuntu-") || $0.hasPrefix("windows-") || $0.hasPrefix("macos-") || $0 == "ubuntu-latest" }) {
            return .github
        }
        if l.contains(where: { $0.contains("mac") || $0 == "osx" }) { return .mac }
        if l.contains(where: { $0.contains("linux") }) { return .linux }
        if l.contains("self-hosted") { return .other }
        return .other
    }
}

struct Config: Decodable {
    /// Explicit "owner/repo" list. When empty, repos pushed within `recentDays` are scanned.
    var repos: [String]?
    var recentDays: Double?
    var maxRepos: Int?
    var refreshSeconds: Double?
    /// ssh arguments for Linux runner hosts, e.g. [["-F", "~/.ssh/vm.config", "my-vm"]].
    /// CPU per job is read from each runner's systemd service (actions.runner.*).
    var sshCpuHosts: [[String]]?
    /// Hours of history to rebuild from GitHub on first launch (0 disables).
    var backfillHours: Double?
    /// Panel text size multiplier (default 2).
    var textScale: Double?
    /// Section columns: 1 or 2 (default: 2 when the screen is wide enough).
    var columns: Int?
    /// T3 Code state database (default ~/.t3/userdata/statev2.sqlite).
    var t3StateDb: String?

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/ciqueuebar")
    }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("config.json")),
              let c = try? JSONDecoder().decode(Config.self, from: data) else { return Config() }
        return c
    }
}

struct Snapshot {
    var jobs: [Job] = []
    var runners: [Runner] = []
    var repoCount = 0
    var rateRemaining: Int?
    var rateLimit: Int?
}

struct BucketGroup: Identifiable {
    var id: String { bucket.id }
    let bucket: Bucket
    let queued: [Job]
    let running: [Job]
    let runners: [Runner]

    var longestWait: TimeInterval? {
        queued.compactMap(\.createdAt).min().map { Date().timeIntervalSince($0) }
    }
}

extension Snapshot {
    var groups: [BucketGroup] {
        Bucket.allCases.compactMap { b in
            let js = jobs.filter { Bucket.classify($0.labels, runners: runners) == b }
            let rs = runners.filter { Bucket.forRunner($0) == b }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            guard !js.isEmpty || !rs.isEmpty else { return nil }
            return BucketGroup(
                bucket: b,
                queued: js.filter { !$0.isRunning }.sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) },
                running: js.filter(\.isRunning).sorted { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) },
                runners: rs)
        }
    }
}

func shortDuration(_ t: TimeInterval) -> String {
    let s = max(0, Int(t))
    if s < 60 { return "\(s)s" }
    let m = s / 60
    if m < 60 { return "\(m)m" }
    return "\(m / 60)h \(m % 60)m"
}
