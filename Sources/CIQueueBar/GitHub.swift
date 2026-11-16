import Foundation

struct Job: Hashable {
    let repo: String
    let workflow: String
    let name: String
    let status: String   // queued | in_progress | waiting | pending
    let labels: [String]
    let url: URL?
    let createdAt: Date?
    let runnerName: String?
}

enum Bucket: String, CaseIterable {
    case mac = "Mac"
    case blacksmith = "Blacksmith"
    case github = "GitHub"
    case selfHosted = "Self-hosted"
    case other = "Other"

    var short: String {
        switch self {
        case .mac: return "Mac"
        case .blacksmith: return "BS"
        case .github: return "GH"
        case .selfHosted: return "SH"
        case .other: return "?"
        }
    }

    static func classify(_ labels: [String]) -> Bucket {
        let l = labels.map { $0.lowercased() }
        if l.contains(where: { $0.hasPrefix("blacksmith") }) { return .blacksmith }
        if l.contains("self-hosted") {
            return l.contains(where: { $0.contains("macos") || $0 == "mac" || $0 == "osx" }) ? .mac : .selfHosted
        }
        if l.contains(where: { $0.hasPrefix("ubuntu") || $0.hasPrefix("windows") || $0.hasPrefix("macos") }) {
            return .github
        }
        return .other
    }
}

struct Config: Decodable {
    /// Explicit "owner/repo" list. When empty, repos pushed within `recentDays` are scanned.
    var repos: [String]?
    var recentDays: Double?
    var maxRepos: Int?
    var refreshSeconds: Double?

    static func load() -> Config {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ciqueuebar/config.json")
        guard let data = try? Data(contentsOf: url),
              let c = try? JSONDecoder().decode(Config.self, from: data) else { return Config() }
        return c
    }
}

final class GitHubClient {
    private var token: String?
    private let session = URLSession(configuration: .ephemeral)
    private let iso = ISO8601DateFormatter()

    private func loadToken() throws -> String {
        if let t = token { return t }
        if let env = ProcessInfo.processInfo.environment["GITHUB_TOKEN"], !env.isEmpty { token = env; return env }
        for path in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"] where FileManager.default.isExecutableFile(atPath: path) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = ["auth", "token"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            try p.run()
            p.waitUntilExit()
            let t = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !t.isEmpty { token = t; return t }
        }
        throw NSError(domain: "CIQueueBar", code: 1, userInfo: [NSLocalizedDescriptionKey: "No GitHub token. Run `gh auth login` or set GITHUB_TOKEN."])
    }

    private func get(_ path: String) async throws -> Any {
        var req = URLRequest(url: URL(string: "https://api.github.com" + path)!)
        req.setValue("Bearer \(try loadToken())", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("CIQueueBar", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            if http.statusCode == 401 { token = nil }
            throw NSError(domain: "CIQueueBar", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "GitHub \(http.statusCode) for \(path)"])
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    func repos(config: Config) async throws -> [String] {
        if let r = config.repos, !r.isEmpty { return r }
        let cutoff = Date().addingTimeInterval(-(config.recentDays ?? 2) * 86400)
        let arr = try await get("/user/repos?sort=pushed&per_page=100&affiliation=owner,collaborator,organization_member") as? [[String: Any]] ?? []
        return arr.compactMap { r -> String? in
            guard let name = r["full_name"] as? String,
                  let pushed = (r["pushed_at"] as? String).flatMap(iso.date(from:)),
                  pushed > cutoff else { return nil }
            return name
        }.prefix(config.maxRepos ?? 25).map { $0 }
    }

    func activeJobs(repo: String) async throws -> [Job] {
        var runs: [[String: Any]] = []
        for status in ["queued", "in_progress", "waiting", "pending"] {
            let obj = try await get("/repos/\(repo)/actions/runs?status=\(status)&per_page=50") as? [String: Any]
            runs += obj?["workflow_runs"] as? [[String: Any]] ?? []
        }
        var jobs: [Job] = []
        for run in runs {
            guard let id = run["id"] as? Int else { continue }
            let wf = run["name"] as? String ?? "workflow"
            let obj = try await get("/repos/\(repo)/actions/runs/\(id)/jobs?filter=latest&per_page=100") as? [String: Any]
            for j in obj?["jobs"] as? [[String: Any]] ?? [] {
                let status = j["status"] as? String ?? ""
                guard status != "completed" else { continue }
                jobs.append(Job(
                    repo: repo, workflow: wf,
                    name: j["name"] as? String ?? "job",
                    status: status,
                    labels: j["labels"] as? [String] ?? [],
                    url: (j["html_url"] as? String).flatMap(URL.init(string:)),
                    createdAt: (j["created_at"] as? String).flatMap(iso.date(from:)),
                    runnerName: j["runner_name"] as? String))
            }
        }
        return jobs
    }

    func allActiveJobs(config: Config) async throws -> [Job] {
        let repos = try await repos(config: config)
        return try await withThrowingTaskGroup(of: [Job].self) { group in
            for r in repos { group.addTask { (try? await self.activeJobs(repo: r)) ?? [] } }
            var all: [Job] = []
            for try await j in group { all += j }
            return all
        }
    }
}
