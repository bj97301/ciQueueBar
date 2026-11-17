import Foundation

final class GitHubClient: @unchecked Sendable {
    private var token: String?
    private let session = URLSession(configuration: .ephemeral)
    private let lock = NSLock()
    private(set) var rateRemaining: Int?
    private(set) var rateLimit: Int?

    private static func parseDate(_ s: Any?) -> Date? {
        guard let s = s as? String else { return nil }
        return ISO8601DateFormatter().date(from: s)
    }

    private func loadToken() throws -> String {
        lock.lock(); defer { lock.unlock() }
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

    func get(_ path: String) async throws -> Any {
        var req = URLRequest(url: URL(string: "https://api.github.com" + path)!)
        req.setValue("Bearer \(try loadToken())", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("CIQueueBar", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse {
            lock.withLock {
            if let r = (http.value(forHTTPHeaderField: "x-ratelimit-remaining")).flatMap(Int.init) { rateRemaining = r }
            if let r = (http.value(forHTTPHeaderField: "x-ratelimit-limit")).flatMap(Int.init) { rateLimit = r }
            if http.statusCode == 401 { token = nil }
            }
            if http.statusCode >= 400 {
                throw NSError(domain: "CIQueueBar", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "GitHub \(http.statusCode) for \(path)"])
            }
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    func repos(config: Config) async throws -> [String] {
        if let r = config.repos, !r.isEmpty { return r }
        let cutoff = Date().addingTimeInterval(-(config.recentDays ?? 2) * 86400)
        let arr = try await get("/user/repos?sort=pushed&per_page=100&affiliation=owner,collaborator,organization_member") as? [[String: Any]] ?? []
        return arr.compactMap { r -> String? in
            guard let name = r["full_name"] as? String,
                  let pushed = Self.parseDate(r["pushed_at"]), pushed > cutoff else { return nil }
            return name
        }.prefix(config.maxRepos ?? 25).map { $0 }
    }

    func activeJobs(repo: String) async throws -> [Job] {
        var runs: [[String: Any]] = []
        var seen = Set<Int>()
        // One call per repo: newest runs, keep the unfinished ones.
        let obj = try await get("/repos/\(repo)/actions/runs?per_page=60") as? [String: Any]
        for r in obj?["workflow_runs"] as? [[String: Any]] ?? [] where (r["status"] as? String) != "completed" {
            if let id = r["id"] as? Int, seen.insert(id).inserted { runs.append(r) }
        }
        var jobs: [Job] = []
        for run in runs {
            guard let id = run["id"] as? Int else { continue }
            let commit = (run["head_commit"] as? [String: Any])?["message"] as? String
            let actor = ((run["triggering_actor"] ?? run["actor"]) as? [String: Any])?["login"] as? String
            let obj = try await get("/repos/\(repo)/actions/runs/\(id)/jobs?filter=latest&per_page=100") as? [String: Any]
            for j in obj?["jobs"] as? [[String: Any]] ?? [] {
                let status = j["status"] as? String ?? ""
                guard status != "completed" else { continue }
                let steps = j["steps"] as? [[String: Any]] ?? []
                let progress: StepProgress? = steps.isEmpty ? nil : StepProgress(
                    done: steps.filter { ($0["status"] as? String) == "completed" }.count,
                    total: steps.count,
                    current: steps.first { ($0["status"] as? String) == "in_progress" }?["name"] as? String)
                jobs.append(Job(
                    id: j["id"] as? Int ?? 0,
                    repo: repo,
                    workflow: run["name"] as? String ?? "workflow",
                    name: j["name"] as? String ?? "job",
                    status: status,
                    labels: j["labels"] as? [String] ?? [],
                    url: (j["html_url"] as? String).flatMap(URL.init(string:)),
                    createdAt: Self.parseDate(j["created_at"]),
                    startedAt: status == "in_progress" ? Self.parseDate(j["started_at"]) : nil,
                    runnerName: (j["runner_name"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                    runNumber: run["run_number"] as? Int,
                    runAttempt: run["run_attempt"] as? Int,
                    branch: run["head_branch"] as? String,
                    event: run["event"] as? String,
                    actor: actor,
                    commitTitle: commit?.split(separator: "\n").first.map(String.init),
                    steps: progress))
            }
        }
        return jobs
    }

    /// Self-hosted runners for each owner. Org endpoint first; personal accounts fall back to per-repo.
    func runners(owners: Set<String>, repos: [String]) async -> [Runner] {
        var out: [Runner] = []
        for owner in owners.sorted() {
            if let obj = try? await get("/orgs/\(owner)/actions/runners?per_page=100") as? [String: Any] {
                out += parseRunners(obj, owner: owner)
                continue
            }
            for repo in repos where repo.hasPrefix(owner + "/") {
                if let obj = try? await get("/repos/\(repo)/actions/runners?per_page=100") as? [String: Any] {
                    out += parseRunners(obj, owner: repo)
                }
            }
        }
        var seen = Set<String>()
        // Blacksmith registers its short-lived VMs as runners too; they aren't your machines.
        return out.filter { !$0.name.hasPrefix("blacksmith") && seen.insert($0.name).inserted }
    }

    private func parseRunners(_ obj: [String: Any], owner: String) -> [Runner] {
        (obj["runners"] as? [[String: Any]] ?? []).map { r in
            Runner(owner: owner,
                   name: r["name"] as? String ?? "runner",
                   os: r["os"] as? String ?? "",
                   online: (r["status"] as? String) == "online",
                   busy: r["busy"] as? Bool ?? false,
                   labels: (r["labels"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String })
        }
    }

    /// Rebuilds per-minute queued/running counts from recent runs' job timestamps.
    func backfill(config: Config, runners: [Runner]) async -> [Sample] {
        let hours = config.backfillHours ?? 24
        guard hours > 0, let repos = try? await repos(config: config) else { return [] }
        let since = Date().addingTimeInterval(-hours * 3600)
        let day = ISO8601DateFormatter.string(from: since, timeZone: .gmt, formatOptions: [.withFullDate])
        struct Span { let bucket: Bucket; let created: Date; let started: Date?; let ended: Date?; let ref: JobRef }
        let spans: [Span] = await withTaskGroup(of: [Span].self) { group in
            for repo in repos {
                group.addTask {
                    var out: [Span] = []
                    var runs: [[String: Any]] = []
                    for page in 1...3 {
                        let obj = try? await self.get("/repos/\(repo)/actions/runs?per_page=100&page=\(page)&created=%3E%3D\(day)") as? [String: Any]
                        let batch = obj?["workflow_runs"] as? [[String: Any]] ?? []
                        runs += batch.filter { (Self.parseDate($0["updated_at"]) ?? .distantFuture) >= since }
                        if batch.count < 100 { break }
                    }
                    for run in runs {
                        guard let id = run["id"] as? Int,
                              let jobs = try? await self.get("/repos/\(repo)/actions/runs/\(id)/jobs?filter=all&per_page=100") as? [String: Any]
                        else { continue }
                        for j in jobs["jobs"] as? [[String: Any]] ?? [] {
                            guard let created = Self.parseDate(j["created_at"]) else { continue }
                            out.append(Span(bucket: Bucket.classify(j["labels"] as? [String] ?? [], runners: runners),
                                            created: created,
                                            // queued jobs report started_at == created_at
                                            started: ["queued", "waiting", "pending"].contains(j["status"] as? String ?? "") ? nil : Self.parseDate(j["started_at"]),
                                            ended: Self.parseDate(j["completed_at"]),
                                            ref: JobRef(r: repo.split(separator: "/").last.map(String.init) ?? repo,
                                                        br: run["head_branch"] as? String,
                                                        w: run["name"] as? String ?? "workflow",
                                                        n: j["name"] as? String ?? "job")))
                        }
                    }
                    return out
                }
            }
            var all: [Span] = []
            for await s in group { all += s }
            return all
        }
        var samples: [Sample] = []
        var t = since
        let now = Date()
        while t < now {
            var b: [String: [Double]] = [:]
            var refs: [String: JobRefs] = [:]
            for s in spans where s.created <= t && (s.ended ?? now) > t {
                var v = b[s.bucket.key] ?? [0, 0, -1]
                var r = refs[s.bucket.key] ?? JobRefs()
                if let st = s.started, st <= t { v[1] += 1; r.run.append(s.ref) } else { v[0] += 1; r.q.append(s.ref) }
                b[s.bucket.key] = v
                refs[s.bucket.key] = r
            }
            for bucket in Bucket.allCases where b[bucket.key] == nil { b[bucket.key] = [0, 0, -1] }
            samples.append(Sample(t: t.timeIntervalSince1970, b: b, j: refs))
            t += 60
        }
        return samples
    }

    func snapshot(config: Config) async throws -> Snapshot {
        let repos = try await repos(config: config)
        async let jobs: [Job] = withTaskGroup(of: [Job].self) { group in
            for r in repos { group.addTask { (try? await self.activeJobs(repo: r)) ?? [] } }
            var all: [Job] = []
            for await j in group { all += j }
            return all
        }
        let owners = Set(repos.compactMap { $0.split(separator: "/").first.map(String.init) })
        async let runners = runners(owners: owners, repos: repos)
        var s = Snapshot()
        s.jobs = await jobs
        s.runners = await runners
        s.repoCount = repos.count
        s.rateRemaining = rateRemaining
        s.rateLimit = rateLimit
        return s
    }
}
