import Foundation
import SQLite3

/// The T3 Code thread a job most likely came from.
struct T3Link: Hashable {
    let threadId: String
    let title: String
    let url: URL
    /// How it was matched: "PR #123" or "branch".
    let via: String
}

/// Matches GitHub runs to T3 Code threads using T3's local state database (read-only):
/// first by pull request (the run's PR, or "Merge pull request #N" pushes), then by branch.
final class T3Index: @unchecked Sendable {
    private struct Thread { let id: String; let title: String; let updated: String }
    private var byPR: [String: Thread] = [:]        // "owner/repo#123"
    private var byBranch: [String: Thread] = [:]    // "owner/repo|branch"
    private var envId: String?
    private var loadedAt: Date = .distantPast
    private var repoForRoot: [String: String?] = [:]
    private let lock = NSLock()

    static let defaultBranches: Set<String> = ["main", "master", "production", "dev", "develop", "staging"]

    private var home: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".t3/userdata")
    }

    /// Reloads at most every 30 seconds.
    func refresh(dbPath: String?) {
        lock.lock(); defer { lock.unlock() }
        guard Date().timeIntervalSince(loadedAt) > 30 else { return }
        loadedAt = Date()
        envId = (try? String(contentsOf: home.appendingPathComponent("environment-id"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let path = dbPath.map { ($0 as NSString).expandingTildeInPath } ?? home.appendingPathComponent("statev2.sqlite").path
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 500)

        var roots: [String: String] = [:]
        query(db, "select project_id, workspace_root from projection_projects where deleted_at is null") { roots[$0[0]] = $0[1] }

        var pr: [String: Thread] = [:], branch: [String: Thread] = [:]
        let sql = """
            select thread_id, title, project_id, payload_json, updated_at from orchestration_v2_projection_threads
            where deleted_at is null and updated_at > datetime('now', '-45 days') order by updated_at
            """
        query(db, sql) { row in
            let t = Thread(id: row[0], title: row[1], updated: row[4])
            guard let data = row[3].data(using: .utf8),
                  let p = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let worktree = p["worktreePath"] as? String
            let repo = worktree.flatMap { self.repo(forRoot: $0) } ?? self.repo(forRoot: roots[row[2]] ?? "")
            if let repo, let b = p["branch"] as? String, !Self.defaultBranches.contains(b) {
                branch["\(repo)|\(b)"] = t   // later (newer) threads win
            }
            for item in p["pullRequests"] as? [[String: Any]] ?? [] {
                guard let r = (item["repository"] as? String)?.lowercased(), let n = item["number"] as? Int else { continue }
                pr["\(r)#\(n)"] = t
                if let head = (item["snapshot"] as? [String: Any])?["headBranch"] as? String,
                   !Self.defaultBranches.contains(head) {
                    branch["\(r)|\(head)"] = branch["\(r)|\(head)"] ?? t
                }
            }
        }
        byPR = pr
        byBranch = branch
    }

    func link(repo: String, branch: String?, prNumbers: [Int]) -> T3Link? {
        lock.lock(); defer { lock.unlock() }
        guard let envId else { return nil }
        let r = repo.lowercased()
        for n in prNumbers { if let t = byPR["\(r)#\(n)"] { return make(t, envId, via: "PR #\(n)") } }
        if let b = branch, let t = byBranch["\(r)|\(b)"] { return make(t, envId, via: "branch") }
        return nil
    }

    private func make(_ t: Thread, _ env: String, via: String) -> T3Link? {
        guard let url = URL(string: "t3code://threads/\(env)/\(t.id)") else { return nil }
        return T3Link(threadId: t.id, title: t.title, url: url, via: via)
    }

    /// "owner/repo" (lowercased) from the folder's git origin remote, read from .git/config; cached.
    /// Folders macOS guards with a privacy prompt; never read inside them.
    private static let protectedFolders: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music", "Library/Mobile Documents"]
            .map { "\(home)/\($0)" }
    }()

    private func repo(forRoot root: String) -> String? {
        guard !root.isEmpty,
              !Self.protectedFolders.contains(where: { root == $0 || root.hasPrefix($0 + "/") }) else { return nil }
        if let cached = repoForRoot[root] { return cached }
        let result = gitConfigPath(root).flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }.flatMap(Self.originRepo)
        repoForRoot[root] = result
        return result
    }

    /// <root>/.git/config, or for a worktree (.git is a file) the main repo's config.
    private func gitConfigPath(_ root: String) -> String? {
        let dotGit = root + "/.git"
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDir) else { return nil }
        if isDir.boolValue { return dotGit + "/config" }
        guard let text = try? String(contentsOfFile: dotGit, encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        var gitdir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        if !gitdir.hasPrefix("/") { gitdir = root + "/" + gitdir }
        // <main>/.git/worktrees/<name> -> commondir points back to <main>/.git
        if let common = try? String(contentsOfFile: gitdir + "/commondir", encoding: .utf8) {
            let c = common.trimmingCharacters(in: .whitespacesAndNewlines)
            return (c.hasPrefix("/") ? c : gitdir + "/" + c) + "/config"
        }
        return gitdir + "/config"
    }

    static func originRepo(_ config: String) -> String? {
        var inOrigin = false
        for raw in config.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inOrigin = line == "[remote \"origin\"]"; continue }
            guard inOrigin, line.hasPrefix("url") , let eq = line.firstIndex(of: "=") else { continue }
            let url = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            // git@github.com:owner/repo.git or https://github.com/owner/repo(.git)
            guard let r = url.range(of: #"github\.com[:/]"#, options: .regularExpression) else { return nil }
            var path = String(url[r.upperBound...])
            if path.hasSuffix(".git") { path.removeLast(4) }
            return path.lowercased()
        }
        return nil
    }

    private func query(_ db: OpaquePointer?, _ sql: String, _ row: ([String]) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        let cols = sqlite3_column_count(stmt)
        while sqlite3_step(stmt) == SQLITE_ROW {
            row((0..<cols).map { i in sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" })
        }
    }
}
