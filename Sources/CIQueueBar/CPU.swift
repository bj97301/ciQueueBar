import Foundation

/// Measures CPU per self-hosted runner, in cores (1.0 = one core fully busy).
/// - Local runners: sums `ps` CPU over each Runner.Worker process and its descendants.
/// - Linux runners over ssh: delta of systemd CPUUsageNSec for each actions.runner.* service.
final class CPUSampler: @unchecked Sendable {
    private var rootNames: [String: String] = [:]
    private var linuxPrev: [String: (ns: UInt64, at: Date)] = [:]
    private let lock = NSLock()

    func sample(sshHosts: [[String]]) -> [String: Double] {
        lock.lock(); defer { lock.unlock() }
        var out = localRunners()
        for host in sshHosts { out.merge(linuxRunners(host), uniquingKeysWith: +) }
        return out
    }

    private func localRunners() -> [String: Double] {
        guard let text = run("/bin/ps", ["-axo", "pid=,ppid=,pcpu=,command="]) else { return [:] }
        var children: [Int: [Int]] = [:]
        var cpu: [Int: Double] = [:]
        var workers: [(pid: Int, path: String)] = []
        var commands: [Int: String] = [:]
        for line in text.split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard f.count == 4, let pid = Int(f[0]), let ppid = Int(f[1]), let c = Double(f[2]) else { continue }
            children[ppid, default: []].append(pid)
            cpu[pid] = c
            let cmd = String(f[3])
            commands[pid] = cmd
            if let r = cmd.range(of: "/Runner.Worker") { workers.append((pid, String(cmd[..<r.lowerBound]))) }
        }
        var result: [String: Double] = [:]
        var counted = Set<Int>()
        for w in workers {
            // <root>/bin.x.y.z/Runner.Worker -> runner name from <root>/.runner
            let root = URL(fileURLWithPath: w.path).deletingLastPathComponent().path
            let name = runnerName(root: root)
            var total = 0.0, stack = [w.pid]
            while let p = stack.popLast() { counted.insert(p); total += cpu[p] ?? 0; stack += children[p] ?? [] }
            result[name, default: 0] += total / 100
        }
        // Detached leftovers (daemons a job started) still live under the slot's folder: .../slots/<runner>/...
        for (pid, cmd) in commands where !counted.contains(pid) && (cpu[pid] ?? 0) > 0 {
            guard let r = cmd.range(of: "/slots/") else { continue }
            let name = cmd[r.upperBound...].prefix { $0 != "/" && $0 != " " }
            if !name.isEmpty, !cmd.contains("Runner.Listener") { result[String(name), default: 0] += (cpu[pid] ?? 0) / 100 }
        }
        return result
    }

    private func runnerName(root: String) -> String {
        if let n = rootNames[root] { return n }
        var name = URL(fileURLWithPath: root).lastPathComponent
        if var data = FileManager.default.contents(atPath: root + "/.runner") {
            if data.starts(with: [0xEF, 0xBB, 0xBF]) { data = data.dropFirst(3) }
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let n = obj["agentName"] as? String { name = n }
        }
        rootNames[root] = name
        return name
    }

    private func linuxRunners(_ host: [String]) -> [String: Double] {
        let args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=3"]
            + host.map { ($0 as NSString).expandingTildeInPath }
            + ["systemctl show -p Id -p CPUUsageNSec 'actions.runner.*'"]
        guard let text = run("/usr/bin/ssh", args, timeout: 8) else { return [:] }
        let now = Date()
        var result: [String: Double] = [:]
        for block in text.components(separatedBy: "\n\n") {
            var id: String?, ns: UInt64?
            for l in block.split(separator: "\n") {
                if l.hasPrefix("Id=") { id = String(l.dropFirst(3)) }
                if l.hasPrefix("CPUUsageNSec=") { ns = UInt64(l.dropFirst(13)) }
            }
            // actions.runner.<owner>.<runner-name>.service
            guard var id, let ns, id.hasPrefix("actions.runner."), id.hasSuffix(".service") else { continue }
            id = String(id.dropFirst("actions.runner.".count).dropLast(".service".count))
            guard let dot = id.firstIndex(of: ".") else { continue }
            let name = String(id[id.index(after: dot)...])
            if let prev = linuxPrev[name], ns >= prev.ns {
                let dt = now.timeIntervalSince(prev.at)
                if dt > 0.5 { result[name] = Double(ns - prev.ns) / 1e9 / dt }
            }
            linuxPrev[name] = (ns, now)
        }
        return result
    }

    private func run(_ exe: String, _ args: [String], timeout: TimeInterval = 5) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return p.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
    }
}
